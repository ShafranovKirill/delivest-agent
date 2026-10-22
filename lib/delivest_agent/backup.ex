defmodule DelivestAgent.Backup do
  alias DelivestAgent.{Compose, Config, Project, Runner}

  @service "postgres"
  @container_dump "/tmp/delivest-backup.dump"
  @container_restore "/tmp/delivest-restore.dump"

  @dump_script ~S"""
  set -e
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --exclude-table-data=app_logs -f "$1"
  """

  @restore_script ~S"""
  set -e
  db="$POSTGRES_DB"
  user="$POSTGRES_USER"
  sql() { psql -U "$user" -d postgres -v ON_ERROR_STOP=1 -q "$@"; }

  sql -c "DROP DATABASE IF EXISTS \"${db}_restore\""
  createdb -U "$user" "${db}_restore"

  if ! pg_restore -U "$user" -d "${db}_restore" --no-owner --no-privileges --exit-on-error --single-transaction "$1"; then
    sql -c "DROP DATABASE IF EXISTS \"${db}_restore\""
    echo "restore failed, the live database is untouched" >&2
    exit 1
  fi

  sql -o /dev/null <<SQL
  DROP DATABASE IF EXISTS "${db}_before_restore";
  SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname = '${db}' AND pid <> pg_backend_pid();
  ALTER DATABASE "${db}" RENAME TO "${db}_before_restore";
  ALTER DATABASE "${db}_restore" RENAME TO "${db}";
  SQL

  echo "restored into ${db}, the previous database is kept as ${db}_before_restore"
  """

  def dir, do: Path.join(Config.get(:data_dir, "/data"), "backups")

  def dump_path, do: Path.join(dir(), "backup.dump")
  def restore_path, do: Path.join(dir(), "restore.dump")

  def dump(%Project{} = project) do
    with :ok <- prepare(dump_path()),
         {:ok, _output} <- postgres(project, @dump_script, @container_dump),
         {:ok, _output} <-
           Compose.run(project, ["cp", "#{@service}:#{@container_dump}", dump_path()]),
         {:ok, _output} <-
           Compose.run(project, ["exec", "-T", @service, "rm", "-f", @container_dump]),
         {:ok, %{size: size}} <- stat(dump_path()) do
      {:ok, "database dump is #{size} bytes"}
    end
  end

  def upload(%{"upload_url" => url, "token" => token}) when is_binary(url) and is_binary(token) do
    curl(
      [
        "--request",
        "PUT",
        "--header",
        "Content-Type: application/octet-stream",
        "--upload-file",
        dump_path(),
        url
      ],
      token
    )
  end

  def upload(_args), do: {:error, {1, "upload_url and token are required"}}

  def download(%{"download_url" => url, "token" => token})
      when is_binary(url) and is_binary(token) do
    with :ok <- prepare(restore_path()),
         {:ok, _output} <- curl(["--output", restore_path(), url], token),
         {:ok, %{size: size}} <- stat(restore_path()) do
      {:ok, "downloaded #{size} bytes"}
    end
  end

  def download(_args), do: {:error, {1, "download_url and token are required"}}

  def restore(%Project{} = project) do
    with {:ok, _output} <-
           Compose.run(project, ["cp", restore_path(), "#{@service}:#{@container_restore}"]) do
      result = postgres(project, @restore_script, @container_restore)
      Compose.run(project, ["exec", "-T", @service, "rm", "-f", @container_restore])
      result
    end
  end

  def cleanup do
    File.rm(dump_path())
    File.rm(restore_path())
    :ok
  end

  defp postgres(project, script, file),
    do: Compose.run(project, ["exec", "-T", @service, "sh", "-c", script, "sh", file])

  defp curl(args, token) do
    args =
      [
        "--fail-with-body",
        "--silent",
        "--show-error",
        "--retry",
        "2",
        "--header",
        "Authorization: Bearer " <> token,
        "--header",
        "Expect:"
      ] ++ args

    case Runner.cmd("curl", args) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  end

  defp prepare(path) do
    File.rm(path)

    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {1, "cannot create #{dir()}: #{:file.format_error(reason)}"}}
    end
  end

  defp stat(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 -> {:ok, %{size: size}}
      {:ok, _stat} -> {:error, {1, "#{Path.basename(path)} is empty"}}
      {:error, reason} -> {:error, {1, "#{Path.basename(path)}: #{:file.format_error(reason)}"}}
    end
  end
end
