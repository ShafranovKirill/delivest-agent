defmodule DelivestAgent.FullBackup do
  @moduledoc false

  alias DelivestAgent.{Compose, OperationLock, Project, Runner}
  alias DelivestAgent.FullBackup.Archive
  alias DelivestAgent.FullBackup.Storage

  @version 1
  @postgres "postgres"
  @s3 "s3"

  def export(%Project{} = project, destination, opts \\ []) do
    OperationLock.with_lock(project, fn -> execute(:export, project, destination, opts) end)
    |> normalize_error()
  end

  def import(%Project{} = project, source, opts \\ []) do
    if opts[:replace] == true do
      OperationLock.with_lock(project, fn -> execute(:import, project, source, opts) end)
      |> normalize_error()
    else
      {:error, {1, "full restore requires --replace"}}
    end
  end

  defp normalize_error({:error, message}) when is_binary(message), do: {:error, {1, message}}
  defp normalize_error(result), do: result

  defp execute(kind, project, path, opts) do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    work = Path.join(System.tmp_dir!(), "delivest-full-backup-#{id}")

    case File.mkdir(work) do
      :ok ->
        File.chmod!(work, 0o700)

        try do
          case kind do
            :export -> do_export(project, path, work, id, opts)
            :import -> do_import(project, path, work, id, opts)
          end
        rescue
          error -> {:error, {1, Exception.message(error)}}
        after
          File.rm_rf(work)
        end

      {:error, reason} ->
        {:error, {1, "cannot create temporary directory: #{:file.format_error(reason)}"}}
    end
  end

  defp do_export(project, path, work, id, opts) do
    with {:ok, context} <- context(project, opts),
         :ok <- ensure_destination(path) do
      outcome =
        try do
          with :ok <- stop_running(project, context, stop_services(context)),
               :ok <- dump_db(project, context, work, id),
               :ok <- copy_storage(context, work),
               :ok <- tar_storage(work),
               :ok <- Archive.validate(Path.join(work, "storage.tar"), :storage),
               {:ok, db} <- Archive.digest(Path.join(work, "database.dump")),
               {:ok, storage} <- Archive.digest(Path.join(work, "storage.tar")),
               :ok <- write_manifest(work, context, db, storage),
               :ok <- create_output(path),
               :ok <- Archive.create(work, path) do
            File.chmod!(path, 0o600)
            {:ok, "full backup written to #{path}"}
          else
            {:error, message} when is_binary(message) -> {:error, {1, message}}
            other -> other
          end
        rescue
          error -> {:error, {1, Exception.message(error)}}
        after
          cleanup_dump(project, id)
        end

      if Process.delete({__MODULE__, :output_created}) == true and match?({:error, _}, outcome),
        do: File.rm(path)

      if match?({:ok, _}, outcome) and opts[:leave_stopped] == true,
        do: outcome,
        else: finish_services(project, context, outcome)
    end
  end

  defp do_import(project, path, work, id, opts) do
    with :ok <- Archive.extract(path, work),
         {:ok, manifest} <- read_manifest(work),
         :ok <- verify_files(work, manifest),
         :ok <- Archive.validate(Path.join(work, "storage.tar"), :storage),
         {:ok, context} <- context(project, opts),
         :ok <- compatible?(project, context, manifest),
         :ok <- extract_storage(work),
         :ok <- Storage.prepare(work),
         {:ok, staged} <- stage_database(project, context, work, id) do
      outcome =
        try do
          install(project, context, work, staged, id)
        rescue
          error ->
            {:error,
             {2,
              "restore interrupted: #{Exception.message(error)}; application remains stopped; staging database #{staged}"}}
        end

      case outcome do
        {:error, {2, _}} -> outcome
        _ -> finish_services(project, context, outcome)
      end
    else
      {:error, message} when is_binary(message) -> {:error, {1, message}}
      other -> other
    end
  end

  defp context(project, opts) do
    with {:ok, definitions} <- Compose.definitions(project),
         true <- Enum.all?([@postgres, @s3], &Enum.any?(definitions, fn d -> d.name == &1 end)),
         {:ok, containers} <- Compose.ps(project),
         {:ok, pg} <- container(containers, @postgres),
         {:ok, s3} <- container(containers, @s3),
         true <- pg["State"] == "running",
         :ok <- stable_states?(containers),
         :ok <- app_stopped?(containers, opts),
         {:ok, s3_info} <- inspect_container(s3["ID"]),
         {:ok, pg_info} <- inspect_container(pg["ID"]),
         :ok <- compose_identity(project, s3_info),
         :ok <- compose_identity(project, pg_info),
         {:ok, private_bucket} <- private_bucket(project, containers),
         :ok <- volume_check(s3_info),
         :ok <- seaweed_check(s3_info),
         {:ok, major} <- pg_major(project),
         {:ok, migrations} <- migrations(project) do
      {:ok,
       %{
         containers: containers,
         pg: pg,
         s3: s3,
         s3_info: s3_info,
         pg_info: pg_info,
         pg_major: major,
         migrations: migrations,
         agent_service: project.agent_service,
         bucket: env(s3_info, "S3_BUCKET") || "delivest",
         private_bucket: private_bucket
       }}
    else
      false ->
        {:error, {1, "postgres and s3 Compose services with running postgres are required"}}

      {:error, _} = error ->
        error
    end
  end

  defp container(containers, service) do
    case Enum.find(containers, &(&1["Service"] == service)) do
      %{"ID" => id} = container when is_binary(id) and id != "" -> {:ok, container}
      _ -> {:error, {1, "missing #{service} container"}}
    end
  end

  defp app_stopped?(containers, opts) do
    if Enum.any?(containers, &(&1["Service"] == "server")) or opts[:app_stopped] == true do
      :ok
    else
      {:error,
       {1, "no server service; confirm external application is stopped with --app-stopped"}}
    end
  end

  defp inspect_container(id) do
    with {:ok, output} <- docker(["inspect", id]),
         {:ok, [%{} = info]} <- Jason.decode(output) do
      {:ok, info}
    else
      _ -> {:error, {1, "cannot inspect container #{id}"}}
    end
  end

  defp volume_check(info) do
    if Enum.any?(info["Mounts"] || [], &(&1["Destination"] == "/data")) do
      :ok
    else
      {:error, {1, "s3 container does not mount /data"}}
    end
  end

  defp compose_identity(project, info) do
    labels = get_in(info, ["Config", "Labels"]) || %{}

    if labels["com.docker.compose.project"] == project.name and
         Path.expand(labels["com.docker.compose.project.working_dir"] || "") ==
           Path.expand(project.dir) do
      :ok
    else
      {:error, {1, "container belongs to another Compose project or directory"}}
    end
  end

  defp seaweed_check(info) do
    config = info["Config"] || %{}
    command = Enum.join((config["Entrypoint"] || []) ++ (config["Cmd"] || []), " ")

    if String.contains?(command, "weed server") and
         Regex.match?(~r/(?:^|\s)-dir=\/data(?:\s|$)/, command) and
         not Regex.match?(~r/-(?:master|filer|volume)\.[a-zA-Z]/, command) and
         not Regex.match?(~r/(?:^|\s)-mdir(?:=|\s)/, command) and
         not Enum.any?(
           info["Mounts"] || [],
           &String.ends_with?(&1["Destination"] || "", "filer.toml")
         ) do
      :ok
    else
      {:error, {1, "unsupported SeaweedFS configuration; expected single weed server -dir=/data"}}
    end
  end

  defp private_bucket(project, containers) do
    case Enum.find(containers, &(&1["Service"] == "server")) do
      nil ->
        {:ok,
         System.get_env("S3_PRIVATE_BUCKET") || project_env(project.dir, "S3_PRIVATE_BUCKET") ||
           "delivest-private"}

      %{"ID" => id} ->
        with {:ok, info} <- inspect_container(id) do
          {:ok, env(info, "S3_PRIVATE_BUCKET") || "delivest-private"}
        end
    end
  end

  defp project_env(dir, key) do
    path = Path.join(dir, ".env")

    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.find_value(fn line ->
        case String.split(String.trim(line), "=", parts: 2) do
          [^key, value] -> value |> String.trim() |> String.trim("\"") |> String.trim("'")
          _ -> nil
        end
      end)
    end
  end

  defp env(info, name) do
    Enum.find_value(info["Config"]["Env"] || [], fn item ->
      case String.split(item, "=", parts: 2) do
        [^name, value] -> value
        _ -> nil
      end
    end)
  end

  defp pg_major(project) do
    with {:ok, output} <-
           Compose.run(project, [
             "exec",
             "-T",
             @postgres,
             "sh",
             "-c",
             "psql -U \"$POSTGRES_USER\" -d postgres -Atqc 'SHOW server_version_num'"
           ]),
         {version, _} <- Integer.parse(String.trim(output)) do
      {:ok, div(version, 10_000)}
    else
      _ -> {:error, {1, "cannot determine PostgreSQL major version"}}
    end
  end

  defp migrations(project) do
    script =
      ~S'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "SELECT version FROM schema_migrations ORDER BY version"'

    case Compose.run(project, ["exec", "-T", @postgres, "sh", "-ec", script]) do
      {:ok, output} -> {:ok, String.split(String.trim(output), "\n", trim: true)}
      _ -> {:error, {1, "cannot read schema_migrations"}}
    end
  end

  defp stop_running(project, context, order) do
    Enum.reduce_while(order, :ok, fn service, :ok ->
      if running?(context, service) do
        case Compose.stop(project, [service]) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp stable_states?(containers) do
    if Enum.any?(containers, &(&1["State"] in ["paused", "restarting", "removing", "dead"])) do
      {:error, {1, "Compose containers must be running or stopped before full backup"}}
    else
      :ok
    end
  end

  defp stop_services(context) do
    context.containers
    |> Enum.map(& &1["Service"])
    |> Enum.reject(&(&1 in ["postgres", context.agent_service, "s3"]))
    |> Enum.uniq()
    |> Enum.sort()
    |> Kernel.++(["s3"])
  end

  defp start_services(context) do
    other =
      context.containers
      |> Enum.map(& &1["Service"])
      |> Enum.reject(&(&1 in ["postgres", context.agent_service, "s3", "server", "gateway"]))
      |> Enum.uniq()
      |> Enum.sort()

    ["s3", "server"] ++ other ++ ["gateway"]
  end

  defp running?(context, service) do
    Enum.any?(context.containers, &(&1["Service"] == service and &1["State"] == "running"))
  end

  defp finish_services(project, context, outcome) do
    restart =
      Enum.reduce_while(start_services(context), :ok, fn service, :ok ->
        if running?(context, service) do
          case Compose.run(project, ["start", service]) do
            {:ok, _} when service == "s3" ->
              case wait_s3(context.s3["ID"], 120) do
                :ok -> {:cont, :ok}
                {:error, why} -> {:halt, {:error, "s3 did not become ready: #{why}"}}
              end

            {:ok, _} ->
              {:cont, :ok}

            {:error, {_, message}} ->
              {:halt, {:error, "cannot restart #{service}: #{message}"}}
          end
        else
          {:cont, :ok}
        end
      end)

    case {outcome, restart} do
      {{:ok, message}, :ok} ->
        {:ok, message}

      {{:error, _} = error, :ok} ->
        error

      {{:ok, _}, {:error, reason}} ->
        {:error, {2, reason <> "; application remains stopped"}}

      {{:error, {_, message}}, {:error, reason}} ->
        {:error, {2, message <> "; " <> reason <> "; application remains stopped"}}
    end
  end

  defp wait_s3(_container, 0), do: {:error, "timeout after 120 seconds"}

  defp wait_s3(container, attempts) do
    check = ~S'''
    set -e
    wget -T 2 -qO- http://127.0.0.1:9333/cluster/status | grep -Eq '"IsLeader":[[:space:]]*true'
    wget -T 2 -qO /dev/null http://127.0.0.1:8888/
    status=$(wget -T 2 -S -O /dev/null "http://127.0.0.1:${S3_PORT:-8333}/" 2>&1 || true)
    printf '%s' "$status" | grep -Eq 'HTTP/[0-9.]+ (200|403)'
    '''

    case docker(["exec", container, "sh", "-c", check]) do
      {:ok, _} ->
        :ok

      _ ->
        Process.sleep(1_000)
        wait_s3(container, attempts - 1)
    end
  end

  defp dump_db(project, _context, work, id) do
    remote = "/tmp/delivest-full-#{id}.dump"
    script = ~S'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -f "$1"'

    with {:ok, _} <-
           Compose.run(project, ["exec", "-T", @postgres, "sh", "-ec", script, "sh", remote]),
         {:ok, _} <-
           docker([
             "cp",
             "#{container_id(project, @postgres)}:#{remote}",
             Path.join(work, "database.dump")
           ]) do
      File.chmod!(Path.join(work, "database.dump"), 0o600)
      :ok
    end
  end

  defp cleanup_dump(project, id) do
    Compose.run(project, ["exec", "-T", @postgres, "rm", "-f", "/tmp/delivest-full-#{id}.dump"])
  end

  defp container_id(project, service) do
    {:ok, containers} = Compose.ps(project)
    {:ok, container} = container(containers, service)
    container["ID"]
  end

  defp copy_storage(context, work) do
    case docker(["cp", "#{context.s3["ID"]}:/data", Path.join(work, "data")]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp tar_storage(work) do
    :ok = secure_create(Path.join(work, "storage.tar"))

    case System.cmd(
           "tar",
           ["--format=gnu", "-C", work, "-cf", Path.join(work, "storage.tar"), "data"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> File.chmod!(Path.join(work, "storage.tar"), 0o600)
      {message, _} -> {:error, {1, "creating storage archive: #{message}"}}
    end
  end

  defp write_manifest(work, context, db, storage) do
    manifest = %{
      format: "delivest-full",
      version: @version,
      postgres_major: context.pg_major,
      seaweed_image_id: context.s3_info["Image"],
      seaweed_image: context.s3_info["Config"]["Image"],
      bucket: context.bucket,
      private_bucket: context.private_bucket,
      schema_migrations: context.migrations,
      files: %{database_dump: db, storage_tar: storage}
    }

    path = Path.join(work, "manifest.json")
    File.write!(path, Jason.encode!(manifest), [:binary])
    File.chmod!(path, 0o600)
    :ok
  end

  defp read_manifest(work) do
    path = Path.join(work, "manifest.json")

    with {:ok, %{size: size}} when size <= 1_048_576 <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, %{"format" => "delivest-full", "version" => @version} = manifest} <-
           Jason.decode(bytes),
         :ok <- manifest_shape(manifest) do
      {:ok, manifest}
    else
      _ -> {:error, {1, "invalid or unsupported full backup manifest"}}
    end
  end

  defp manifest_shape(manifest) do
    files = manifest["files"]
    migrations = manifest["schema_migrations"]
    entries = if is_map(files), do: [files["database_dump"], files["storage_tar"]], else: []

    if length(entries) == 2 and
         Enum.all?(entries, fn
           %{"size" => size, "sha256" => hash} ->
             is_integer(size) and size >= 0 and is_binary(hash) and
               Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)

           _ ->
             false
         end) and
         is_list(migrations) and length(migrations) <= 10_000 and
         Enum.all?(
           migrations,
           &(is_binary(&1) and byte_size(&1) <= 32 and Regex.match?(~r/\A[0-9]+\z/, &1))
         ) do
      :ok
    else
      {:error, :invalid_manifest_shape}
    end
  end

  defp verify_files(work, manifest) do
    checks = [{"database.dump", "database_dump"}, {"storage.tar", "storage_tar"}]

    Enum.reduce_while(checks, :ok, fn {name, key}, :ok ->
      with {:ok, actual} <- Archive.digest(Path.join(work, name)),
           %{"size" => size, "sha256" => hash} <- get_in(manifest, ["files", key]),
           true <- actual.size == size and actual.sha256 == hash do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, {1, "#{name} size or SHA256 mismatch"}}}
      end
    end)
  end

  defp compatible?(_project, context, manifest) do
    cond do
      manifest["seaweed_image_id"] != context.s3_info["Image"] ->
        {:error, {1, "SeaweedFS image ID differs from backup"}}

      manifest["bucket"] != context.bucket ->
        {:error, {1, "S3_BUCKET differs from backup"}}

      manifest["private_bucket"] != context.private_bucket ->
        {:error, {1, "S3_PRIVATE_BUCKET differs from backup"}}

      not is_list(manifest["schema_migrations"]) or
          not MapSet.subset?(
            MapSet.new(manifest["schema_migrations"]),
            MapSet.new(context.migrations)
          ) ->
        {:error, {1, "target schema_migrations do not include source versions"}}

      not is_integer(manifest["postgres_major"]) or context.pg_major < manifest["postgres_major"] ->
        {:error, {1, "target PostgreSQL major version is older than source"}}

      true ->
        :ok
    end
  end

  defp ensure_destination(path) do
    if File.exists?(path) do
      {:error, {1, "destination already exists: #{path}"}}
    else
      :ok
    end
  end

  defp secure_create(path) do
    with {:ok, io} <- File.open(path, [:write, :exclusive, :binary]),
         :ok <- File.chmod(path, 0o600) do
      File.close(io)
      :ok
    else
      {:error, reason} -> {:error, {1, "cannot create #{path}: #{:file.format_error(reason)}"}}
    end
  end

  defp create_output(path) do
    case secure_create(path) do
      :ok ->
        Process.put({__MODULE__, :output_created}, true)
        :ok

      other ->
        other
    end
  end

  defp docker(args) do
    case Runner.cmd("docker", args) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  end

  defp extract_storage(work) do
    case System.cmd("tar", ["-C", work, "-xf", Path.join(work, "storage.tar")],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {message, _} -> {:error, {1, "extracting storage: #{message}"}}
    end
  end

  defp stage_database(project, context, work, id) do
    stage = "delivest_restore_#{id}"
    remote = "/tmp/delivest-restore-#{id}.dump"
    create = ~S'createdb -U "$POSTGRES_USER" "$1"'

    restore =
      ~S'pg_restore -U "$POSTGRES_USER" -d "$1" --no-owner --no-privileges --exit-on-error --single-transaction "$2"'

    result =
      with {:ok, _} <-
             docker(["cp", Path.join(work, "database.dump"), "#{context.pg["ID"]}:#{remote}"]),
           {:ok, _} <-
             Compose.run(project, ["exec", "-T", @postgres, "sh", "-ec", create, "sh", stage]),
           {:ok, _} <-
             Compose.run(project, [
               "exec",
               "-T",
               @postgres,
               "sh",
               "-ec",
               restore,
               "sh",
               stage,
               remote
             ]) do
        {:ok, stage}
      end

    Compose.run(project, ["exec", "-T", @postgres, "rm", "-f", remote])
    if match?({:error, _}, result), do: drop_database(project, stage)
    result
  end

  defp drop_database(project, database) do
    script = ~S'dropdb -U "$POSTGRES_USER" --if-exists "$1"'
    Compose.run(project, ["exec", "-T", @postgres, "sh", "-ec", script, "sh", database])
  end

  defp install(project, context, work, stage, id) do
    recovery = Path.join(project.dir, ".delivest-recovery-#{id}")
    previous = "delivest_previous_#{id}"
    helper = "delivest-storage-restore-#{id}"
    File.mkdir!(recovery)
    File.chmod!(recovery, 0o700)

    result =
      with :ok <- stop_running(project, context, stop_services(context)),
           {:ok, _} <- docker(["cp", "#{context.s3["ID"]}:/data", Path.join(recovery, "data")]),
           {:ok, _} <- start_helper(context, helper),
           :ok <- mark_and_replace_storage(helper, Path.join(work, "data")),
           :ok <- swap_databases(project, stage, previous) do
        {:ok,
         "full restore complete; previous database #{previous}, previous storage #{recovery}/data" <>
           if(Process.delete({__MODULE__, :swap_warning}),
             do: "; swap command disconnected after commit",
             else: ""
           )}
      end

    case result do
      {:ok, _} ->
        Process.delete({__MODULE__, :storage_touched})
        docker(["rm", "-f", helper])
        result

      {:error, {2, message}} ->
        Process.delete({__MODULE__, :storage_touched})
        docker(["rm", "-f", helper])

        {:error,
         {2,
          message <>
            "; DB state uncertain; storage left installed; previous storage #{recovery}/data; staging DB #{stage}; previous DB #{previous}; application remains stopped"}}

      {:error, {_, message}} ->
        # Storage may have been touched. The rollback copy is deliberately kept for manual recovery.
        rollback =
          if Process.get({__MODULE__, :storage_touched}),
            do: rollback_storage(helper, Path.join(recovery, "data")),
            else: :ok

        Process.delete({__MODULE__, :storage_touched})
        docker(["rm", "-f", helper])
        drop_database(project, stage)

        case rollback do
          :ok ->
            {:error, {1, message <> "; previous storage restored from #{recovery}/data"}}

          {:error, {_, why}} ->
            {:error,
             {2,
              message <>
                "; STORAGE ROLLBACK FAILED: #{why}; recovery: #{recovery}/data; previous DB: #{previous}; application must remain stopped"}}
        end
    end
  end

  defp start_helper(context, name) do
    image = context.pg_info["Image"]

    docker([
      "run",
      "--detach",
      "--name",
      name,
      "--volumes-from",
      context.s3["ID"],
      "--entrypoint",
      "sh",
      image,
      "-c",
      "sleep 86400"
    ])
  end

  defp replace_storage(helper, directory) do
    with {:ok, _} <-
           docker([
             "exec",
             helper,
             "sh",
             "-ec",
             "find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
           ]),
         {:ok, _} <- docker(["cp", Path.join(directory, "."), "#{helper}:/data/"]) do
      :ok
    end
  end

  defp mark_and_replace_storage(helper, directory) do
    Process.put({__MODULE__, :storage_touched}, true)
    replace_storage(helper, directory)
  end

  defp rollback_storage(helper, directory) do
    if File.dir?(directory) do
      replace_storage(helper, directory)
    else
      {:error, {1, "no cold storage copy"}}
    end
  end

  defp swap_databases(project, stage, previous) do
    script = ~S'''
    set -e
    psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -v current="$POSTGRES_DB" -v previous="$1" -v staged="$2" <<'SQL'
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'current' AND pid <> pg_backend_pid();
    BEGIN;
    SELECT format('ALTER DATABASE %I RENAME TO %I', :'current', :'previous') \gexec
    SELECT format('ALTER DATABASE %I RENAME TO %I', :'staged', :'current') \gexec
    COMMIT;
    SQL
    '''

    case Compose.run(project, [
           "exec",
           "-T",
           @postgres,
           "sh",
           "-ec",
           script,
           "sh",
           previous,
           stage
         ]) do
      {:ok, _} ->
        :ok

      {:error, _} = error ->
        case database_state(project, stage, previous) do
          :committed ->
            Process.put({__MODULE__, :swap_warning}, true)
            :ok

          :uncommitted ->
            error

          :uncertain ->
            {:error, {2, "database swap command failed and commit state cannot be verified"}}
        end
    end
  end

  defp database_state(project, stage, previous) do
    script = ~S'''
    psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -Atq -v current="$POSTGRES_DB" -v previous="$1" -v staged="$2" <<'SQL'
    SELECT CASE
      WHEN EXISTS (SELECT 1 FROM pg_database WHERE datname = :'current') AND
           EXISTS (SELECT 1 FROM pg_database WHERE datname = :'previous') AND
           NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'staged') THEN 'committed'
      WHEN EXISTS (SELECT 1 FROM pg_database WHERE datname = :'current') AND
           NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'previous') AND
           EXISTS (SELECT 1 FROM pg_database WHERE datname = :'staged') THEN 'uncommitted'
      ELSE 'uncertain'
    END;
    SQL
    '''

    case Compose.run(project, [
           "exec",
           "-T",
           @postgres,
           "sh",
           "-ec",
           script,
           "sh",
           previous,
           stage
         ]) do
      {:ok, output} ->
        case String.trim(output) do
          "committed" -> :committed
          "uncommitted" -> :uncommitted
          _ -> :uncertain
        end

      _ ->
        :uncertain
    end
  end
end
