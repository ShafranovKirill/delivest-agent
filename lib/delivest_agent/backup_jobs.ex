defmodule DelivestAgent.BackupJobs do
  @moduledoc false
  use GenServer
  require Logger

  alias DelivestAgent.{Compose, FullBackup, Project}

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @max_json 1_048_576
  @poll_ms 2_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @impl true
  def init(opts) do
    dir =
      opts[:dir] || Application.get_env(:delivest_agent, :instance_backup_dir) ||
        System.get_env("INSTANCE_BACKUP_DIR")

    state = %{
      dir: dir,
      task: nil,
      job: nil,
      engine: opts[:engine] || FullBackup,
      project: opts[:project],
      poll_ms: opts[:poll_ms] || @poll_ms,
      quiesce_timeout_ms: opts[:quiesce_timeout_ms] || 120_000
    }

    if is_binary(dir) and dir != "", do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    heartbeat(state.dir)
    state = if state.task, do: state, else: poll_active(state)
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}, job: job} = state) do
    Process.demonitor(ref, [:flush])
    finish(job, result)
    {:noreply, %{state | task: nil, job: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task: %Task{ref: ref}, job: job} = state
      ) do
    finish(job, {:error, {2, "backup job crashed: #{inspect(reason)}"}})
    {:noreply, %{state | task: nil, job: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{task: %Task{pid: pid}}) do
    Task.Supervisor.terminate_child(DelivestAgent.TaskSupervisor, pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp poll_active(state) do
    with {:ok, %{"id" => id}} <- read_json(Path.join(state.dir, "active.json")),
         true <- valid_uuid?(id),
         job_dir <- Path.join([state.dir, "jobs", id]),
         :ok <- directory?(job_dir),
         {:ok, request} <- read_json(Path.join(job_dir, "request.json")),
         :ok <- validate_request(request, id) do
      claim(state, %{id: id, dir: job_dir, request: request})
    else
      _ -> state
    end
  end

  defp claim(state, job) do
    claim_dir = Path.join(job.dir, "claimed")

    case File.mkdir(claim_dir) do
      :ok ->
        File.chmod(claim_dir, 0o700)
        match_owner(claim_dir, job.dir)
        phase = if job.request["mode"] == "external", do: "waiting", else: "running"

        case write_status(job, phase, "backup job accepted", false) do
          :ok ->
            task =
              Task.Supervisor.async_nolink(DelivestAgent.TaskSupervisor, fn ->
                perform(state, job)
              end)

            %{state | task: task, job: job}

          error ->
            Logger.error("cannot persist backup job status: #{inspect(error)}")
            state
        end

      {:error, :eexist} ->
        case read_json(Path.join(job.dir, "status.json")) do
          {:ok, %{"phase" => phase}} when phase in ["queued", "waiting", "running"] ->
            write_status(
              job,
              "interrupted",
              "agent restarted during backup job; manual review required",
              false
            )

          _ ->
            :ok
        end

        state

      _ ->
        state
    end
  end

  defp perform(state, job) do
    with {:ok, project} <- project(state),
         {:ok, services} <- Compose.services(project),
         :ok <- mode_check(job.request["mode"], services),
         :ok <- wait_quiesced(job, state.quiesce_timeout_ms),
         :ok <- write_status(job, "running", "full #{job.request["action"]} running", false) do
      archive = Path.join(job.dir, "archive.tar")

      result =
        case job.request["action"] do
          "export" ->
            state.engine.export(project, archive, app_stopped: job.request["mode"] == "external")

          "import" ->
            if regular?(archive),
              do:
                state.engine.import(project, archive,
                  replace: true,
                  app_stopped: job.request["mode"] == "external"
                ),
              else: {:error, {1, "uploaded archive.tar is missing"}}
        end

      match_owner(archive, job.dir)
      result
    end
  end

  defp project(%{project: %Project{} = project}), do: {:ok, project}
  defp project(_), do: Project.discover()

  defp mode_check("compose", services) do
    if "server" in services, do: :ok, else: {:error, {1, "compose mode requires server service"}}
  end

  defp mode_check("external", services) do
    if "server" in services,
      do: {:error, {1, "external mode requires no server service"}},
      else: :ok
  end

  defp wait_quiesced(%{request: %{"mode" => "compose"}}, _timeout), do: :ok

  defp wait_quiesced(job, timeout) do
    wait_marker(job, System.monotonic_time(:millisecond) + timeout)
  end

  defp wait_marker(job, deadline) do
    case read_json(Path.join(job.dir, "quiesced.json")) do
      {:ok, %{"id" => id}} when id == job.id ->
        :ok

      _ ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error, {1, "application did not quiesce before timeout"}}
        else
          Process.sleep(min(1_000, remaining))
          wait_marker(job, deadline)
        end
    end
  end

  defp finish(job, {:ok, message}), do: write_status(job, "complete", message, true)
  defp finish(job, {:error, {1, message}}), do: write_status(job, "failed", message, true)
  defp finish(job, {:error, {2, message}}), do: write_status(job, "failed", message, false)

  defp finish(job, other),
    do: write_status(job, "failed", "unexpected result: #{inspect(other)}", false)

  defp validate_request(
         %{
           "version" => 1,
           "id" => id,
           "action" => action,
           "mode" => mode,
           "requested_by" => by,
           "created_at" => at
         } = request,
         expected
       ) do
    if MapSet.new(Map.keys(request)) ==
         MapSet.new(~w(action created_at id mode requested_by version)) and
         id == expected and action in ["export", "import"] and mode in ["compose", "external"] and
         valid_uuid?(by) and valid_time?(at), do: :ok, else: {:error, :invalid_request}
  end

  defp validate_request(_, _), do: {:error, :invalid_request}

  defp valid_uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)

  defp valid_time?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_time?(_), do: false

  defp heartbeat(nil), do: :ok

  defp heartbeat(dir) do
    if File.dir?(dir),
      do: atomic_json(Path.join(dir, "heartbeat.json"), %{protocol: 1, updated_at: now()}, dir)
  end

  defp write_status(job, phase, message, safe) do
    atomic_json(
      Path.join(job.dir, "status.json"),
      %{
        id: job.id,
        action: job.request["action"],
        phase: phase,
        message: to_string(message),
        safe_to_resume: safe,
        updated_at: now()
      },
      job.dir
    )
  end

  defp read_json(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_json <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, %{} = json} <- Jason.decode(bytes) do
      {:ok, json}
    else
      _ -> {:error, :invalid_json}
    end
  end

  defp regular?(path), do: match?({:ok, %{type: :regular}}, File.lstat(path))

  defp directory?(path) do
    if match?({:ok, %{type: :directory}}, File.lstat(path)),
      do: :ok,
      else: {:error, :unsafe_job_directory}
  end

  defp atomic_json(path, data, owner_dir) do
    temp = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(temp, Jason.encode!(data), [:binary]),
         :ok <- File.chmod(temp, 0o600),
         :ok <- match_owner(temp, owner_dir),
         :ok <- File.rename(temp, path) do
      :ok
    else
      error ->
        File.rm(temp)
        error
    end
  end

  defp match_owner(path, owner_dir) do
    case File.lstat(path) do
      {:ok, %{type: type}} when type in [:regular, :directory] ->
        with {:ok, %{uid: uid, gid: gid}} <- File.stat(owner_dir),
             :ok <- :file.change_owner(String.to_charlist(path), uid),
             :ok <- :file.change_group(String.to_charlist(path), gid) do
          :ok
        end

      {:error, :enoent} ->
        :ok

      _ ->
        {:error, :unsafe_file_type}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
