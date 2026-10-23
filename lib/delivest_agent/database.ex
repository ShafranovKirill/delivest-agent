defmodule DelivestAgent.Database do
  alias DelivestAgent.{Compose, Project}

  # One psql call per heartbeat: CRM problems, the order flow against the same hour
  # of the last 4 weeks, application errors and the database size.
  @query """
  WITH n AS (SELECT now() AT TIME ZONE 'utc' AS t)
  SELECT json_build_object(
    'crm', (
      SELECT coalesce(json_agg(c), '[]')
      FROM (
        SELECT o.id, o.number, b.name AS branch, o.crm->>'provider' AS provider,
               o.crm->>'status' AS status, o.crm->>'last_error' AS error,
               coalesce((o.crm->>'attempts')::int, 0) AS attempts, o.inserted_at
        FROM orders o
        LEFT JOIN branches b ON b.id = o.branch_id
        WHERE o.crm IS NOT NULL
          AND o.inserted_at > n.t - interval '24 hours'
          AND (o.crm->>'status' = 'failed'
               OR (o.crm->>'status' = 'pending' AND o.inserted_at < n.t - interval '5 minutes'))
        ORDER BY o.inserted_at DESC
        LIMIT 50
      ) c
    ),
    'orders', (
      SELECT json_build_object(
        'last_hour', coalesce(sum(w.count) FILTER (WHERE w.week = 0), 0),
        'usual', round(coalesce(sum(w.count) FILTER (WHERE w.week > 0), 0)::numeric / 4, 1)
      )
      FROM (
        SELECT week, (
          SELECT count(*) FROM orders o
          WHERE o.deleted_at IS NULL
            AND o.inserted_at > n.t - make_interval(weeks => week) - interval '1 hour'
            AND o.inserted_at <= n.t - make_interval(weeks => week)
        ) AS count
        FROM generate_series(0, 4) AS week
      ) w
    ),
    'errors', (
      SELECT json_build_object(
        'last_5m', count(*) FILTER (WHERE l.inserted_at > n.t - interval '5 minutes'),
        'last_hour', count(*),
        'latest', (
          SELECT coalesce(json_agg(e), '[]')
          FROM (
            SELECT left(message, 300) AS message, source, inserted_at
            FROM app_logs
            WHERE level IN ('error', 'critical', 'alert', 'emergency')
              AND inserted_at > n.t - interval '1 hour'
            ORDER BY inserted_at DESC
            LIMIT 3
          ) e
        )
      )
      FROM app_logs l
      WHERE l.level IN ('error', 'critical', 'alert', 'emergency')
        AND l.inserted_at > n.t - interval '1 hour'
    ),
    'size_bytes', pg_database_size(current_database())
  )
  FROM n
  """

  def query, do: @query

  def stats(%Project{} = project) do
    script = ~S(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -v ON_ERROR_STOP=1 -c "$1")

    with {:ok, output} <-
           Compose.run(project, ["exec", "-T", "postgres", "sh", "-c", script, "sh", @query]),
         {:ok, %{} = stats} <- Jason.decode(String.trim(output)) do
      stats
    else
      _ -> %{}
    end
  end
end
