defmodule DelivestAgent.MigrationLedger do
  alias DelivestAgent.{Project, Runner}

  @query "BEGIN; SET LOCAL lock_timeout = '5s'; LOCK TABLE schema_migrations IN SHARE UPDATE EXCLUSIVE MODE; SELECT version FROM schema_migrations ORDER BY version; COMMIT;"
  @script ~S(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -qAt -v ON_ERROR_STOP=1 -c "$1")

  def versions(%Project{} = project) do
    args = [
      "ps",
      "--filter",
      "label=com.docker.compose.project=#{project.name}",
      "--filter",
      "label=com.docker.compose.service=postgres",
      "--format",
      "{{.ID}}"
    ]

    case Runner.cmd("docker", args) do
      {output, 0} ->
        read_postgres(String.split(output, "\n", trim: true))

      {output, _status} ->
        {:error, {1, "cannot find the running database: #{String.trim(output)}"}}
    end
  end

  defp read_postgres([container]) do
    case Runner.cmd("docker", ["exec", "-i", container, "sh", "-c", @script, "sh", @query]) do
      {output, 0} -> parse(output)
      {output, _status} -> {:error, {1, "cannot read applied migrations: #{String.trim(output)}"}}
    end
  end

  defp read_postgres(_containers),
    do: {:error, {1, "cannot identify exactly one running postgres container"}}

  defp parse(output) do
    versions = String.split(output, "\n", trim: true)

    if Enum.all?(versions, &String.match?(&1, ~r/^\d+$/)) do
      {:ok, versions}
    else
      {:error, {1, "cannot read applied migrations: invalid database response"}}
    end
  end
end
