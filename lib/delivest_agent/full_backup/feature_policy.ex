defmodule DelivestAgent.FullBackup.FeaturePolicy do
  @moduledoc false

  alias DelivestAgent.Compose

  def preserve(project, stage, id) do
    remote = "/tmp/delivest-feature-policy-#{id}.sql"

    try do
      with {:ok, target} <- tables(project, nil),
           {:ok, source} <- tables(project, stage),
           :ok <- compatible_tables(target, source),
           :ok <- apply_policy(project, stage, remote, target) do
        :ok
      end
    after
      Compose.run(project, ["exec", "-T", "postgres", "rm", "-f", remote])
    end
  end

  defp tables(project, database) do
    script = ~S'''
    psql -U "$POSTGRES_USER" -d "${1:-$POSTGRES_DB}" -Atqc "SELECT (to_regclass('public.feature_gates') IS NOT NULL)::int || '|' || (to_regclass('public.feature_audits') IS NOT NULL)::int || '|' || (to_regclass('public.background_schedules') IS NOT NULL)::int"
    '''

    args = if database, do: ["sh", database], else: []

    case Compose.run(project, ["exec", "-T", "postgres", "sh", "-ec", script] ++ args) do
      {:ok, output} -> {:ok, String.trim(output)}
      _ -> {:error, {1, "cannot inspect feature policy tables"}}
    end
  end

  defp compatible_tables("0|0|0", "0|0|0"), do: :ok
  defp compatible_tables("1|1|1", "1|1|1"), do: :ok

  defp compatible_tables(_, _),
    do: {:error, {1, "feature policy schema mismatch; restore aborted"}}

  defp apply_policy(_project, _stage, _remote, "0|0|0"), do: :ok

  defp apply_policy(project, stage, remote, "1|1|1") do
    dump = ~S'''
    umask 077
    pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --data-only --column-inserts --no-owner --no-privileges -t public.feature_gates -t public.feature_audits -f "$1"
    '''

    before_sql = ~S'''
    CREATE TEMP TABLE incoming_feature_generations ON COMMIT DROP AS
      SELECT feature, max(generation) AS generation FROM feature_gates GROUP BY feature;
    TRUNCATE TABLE feature_audits, feature_gates;
    '''

    after_sql = ~S'''
    SET LOCAL search_path TO public, pg_temp;
    DELETE FROM feature_gates g
      WHERE g.scope_key LIKE 'branch:%'
        AND NOT EXISTS (
          SELECT 1 FROM branches b
          WHERE g.scope_key = 'branch:' || b.id::text AND b.deleted_at IS NULL
        );
    UPDATE feature_gates g SET generation = GREATEST(g.generation,
      COALESCE((SELECT i.generation FROM incoming_feature_generations i WHERE i.feature = g.feature), 0)) + 1;
    SELECT setval(pg_get_serial_sequence('public.feature_audits', 'id'),
      COALESCE((SELECT max(id) FROM feature_audits), 1),
      EXISTS (SELECT 1 FROM feature_audits));
    UPDATE oban_jobs SET state = 'cancelled', cancelled_at = now()
      WHERE (worker IN ('Delivest.Background.Runner', 'Delivest.Background.Dispatcher')
        OR (jsonb_typeof(args->'optional_feature') = 'string'
          AND NULLIF(args->>'optional_feature', '') IS NOT NULL))
        AND state IN ('available', 'scheduled', 'retryable', 'executing');
    DELETE FROM background_schedules;
    '''

    apply = ~S'''
    psql -U "$POSTGRES_USER" -d "$1" -v ON_ERROR_STOP=1 --single-transaction \
      -c "$3" -f "$2" -c "$4"
    '''

    with {:ok, _} <-
           Compose.run(project, ["exec", "-T", "postgres", "sh", "-ec", dump, "sh", remote]),
         {:ok, _} <-
           Compose.run(project, [
             "exec",
             "-T",
             "postgres",
             "sh",
             "-ec",
             apply,
             "sh",
             stage,
             remote,
             before_sql,
             after_sql
           ]) do
      :ok
    else
      _ -> {:error, {1, "cannot preserve target host feature policy"}}
    end
  end
end
