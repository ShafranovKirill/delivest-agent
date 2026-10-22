defmodule DelivestAgent.Crm do
  alias DelivestAgent.{Compose, Project}

  @query """
  SELECT coalesce(json_agg(t), '[]')
  FROM (
    SELECT o.id, o.number, b.name AS branch, o.crm->>'provider' AS provider,
           o.crm->>'status' AS status, o.crm->>'last_error' AS error,
           coalesce((o.crm->>'attempts')::int, 0) AS attempts, o.inserted_at
    FROM orders o
    LEFT JOIN branches b ON b.id = o.branch_id
    WHERE o.crm IS NOT NULL
      AND o.inserted_at > (now() AT TIME ZONE 'utc') - interval '24 hours'
      AND (o.crm->>'status' = 'failed'
           OR (o.crm->>'status' = 'pending'
               AND o.inserted_at < (now() AT TIME ZONE 'utc') - interval '5 minutes'))
    ORDER BY o.inserted_at DESC
    LIMIT 50
  ) t
  """

  def query, do: @query

  def problems(%Project{} = project) do
    script = ~S(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -v ON_ERROR_STOP=1 -c "$1")

    with {:ok, output} <-
           Compose.run(project, ["exec", "-T", "postgres", "sh", "-c", script, "sh", @query]),
         {:ok, orders} when is_list(orders) <- Jason.decode(String.trim(output)) do
      orders
    else
      _ -> nil
    end
  end
end
