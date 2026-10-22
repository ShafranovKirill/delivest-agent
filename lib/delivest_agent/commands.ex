defmodule DelivestAgent.Commands do
  alias DelivestAgent.{Backup, Compose, Env, Project, Runner, Status}

  @actions ~w(status update start stop restart logs env_read env_write backup restore)
  @max_output 64_000
  @default_tail 200
  @max_tail 2_000

  def actions, do: @actions

  def run(action, args \\ %{}, project_result \\ Project.discover())

  def run("status", _args, project_result), do: {:ok, Status.collect(project_result)}

  def run("env_read", _args, {:ok, %Project{} = project}), do: Env.read(project)

  def run(action, args, {:ok, %Project{} = project}) when action in @actions do
    with {:ok, services} <- Compose.services(project) do
      action |> execute(args, project, services) |> format()
    end
    |> case do
      {:ok, output} -> {:ok, output}
      {:error, {_status, output}} -> {:error, truncate(output)}
      {:error, output} when is_binary(output) -> {:error, truncate(output)}
    end
  end

  def run(action, _args, {:error, reason}) when action in @actions,
    do: {:error, "compose project is not available: #{inspect(reason)}"}

  def run(action, _args, _project_result), do: {:error, "unknown action: #{action}"}

  defp execute("update", _args, project, services) do
    steps([
      {"git pull", fn -> git_pull(project.dir) end},
      {"docker compose pull", fn -> Compose.pull(project, services) end},
      {"docker compose up", fn -> Compose.up(project, services) end},
      {"gateway restart", fn -> restart_gateway(project, services) end},
      {"docker image prune", fn -> prune_images() end}
    ])
  end

  defp execute("env_write", args, project, services) do
    steps([
      {"write .env", fn -> Env.write(project, args["content"]) end},
      {"docker compose up", fn -> Compose.up(project, services) end},
      {"gateway restart", fn -> restart_gateway(project, services) end}
    ])
  end

  defp execute("backup", args, project, _services) do
    steps([
      {"dump database", fn -> Backup.dump(project) end},
      {"upload to bastion", fn -> Backup.upload(args) end}
    ])
  after
    Backup.cleanup()
  end

  defp execute("restore", args, project, services) do
    server = Enum.filter(services, &(&1 == "server"))

    restored =
      steps([
        {"download backup", fn -> Backup.download(args) end},
        {"stop server", fn -> stop(project, server) end},
        {"restore database", fn -> Backup.restore(project) end}
      ])

    started = steps([{"start server", fn -> start(project, server) end}])
    Backup.cleanup()
    combine(restored, started)
  end

  defp execute("start", _args, project, services), do: Compose.up(project, services)
  defp execute("stop", _args, project, services), do: Compose.stop(project, services)
  defp execute("restart", _args, project, services), do: Compose.restart(project, services)

  defp execute("logs", args, project, services) do
    service = args["service"]

    cond do
      service in [nil, ""] -> Compose.logs(project, services, tail(args["tail"]))
      service in services -> Compose.logs(project, [service], tail(args["tail"]))
      true -> {:error, "unknown service: #{service}"}
    end
  end

  defp stop(_project, []), do: {:skip, "no server service"}
  defp stop(project, services), do: Compose.stop(project, services)

  defp start(_project, []), do: {:skip, "no server service"}
  defp start(project, services), do: Compose.up(project, services)

  defp combine({:ok, first}, {:ok, second}), do: {:ok, first <> second}
  defp combine({_, first}, {_, second}), do: {:error, text(first) <> text(second)}

  defp text({_status, output}), do: output
  defp text(output), do: output

  defp steps(steps) do
    Enum.reduce_while(steps, {:ok, ""}, fn {title, fun}, {:ok, log} ->
      case fun.() do
        {:ok, output} ->
          {:cont, {:ok, log <> section(title, output)}}

        {:skip, reason} ->
          {:cont, {:ok, log <> section(title, "skipped: #{reason}")}}

        {:warn, output} ->
          {:cont, {:ok, log <> section(title <> " (warning)", output)}}

        {:error, {_status, output}} ->
          {:halt, {:error, log <> section(title <> " failed", output)}}
      end
    end)
  end

  defp git_pull(dir) do
    if File.exists?(Path.join(dir, ".git")) do
      {command, args} = as_owner(dir, ["git", "-C", dir, "pull", "--ff-only"])

      case Runner.cmd(command, args) do
        {output, 0} -> {:ok, output}
        {output, _status} -> {:warn, output}
      end
    else
      {:skip, "not a git checkout"}
    end
  end

  defp as_owner(dir, [command | args]) do
    case File.stat(dir) do
      {:ok, %{uid: uid, gid: gid}} when uid != 0 ->
        {"setpriv",
         ["--reuid", to_string(uid), "--regid", to_string(gid), "--clear-groups"] ++
           ["env", "HOME=/tmp", command | args]}

      _ ->
        {command, args}
    end
  end

  defp restart_gateway(project, services) do
    if "gateway" in services,
      do: Compose.restart(project, ["gateway"]),
      else: {:skip, "no gateway service"}
  end

  defp prune_images do
    case Runner.cmd("docker", ["image", "prune", "--force"]) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:warn, output}
    end
  end

  defp section(title, output), do: "== #{title}\n#{String.trim(output)}\n"

  defp format({:ok, output}), do: {:ok, truncate(output)}
  defp format(error), do: error

  defp tail(value) when is_integer(value), do: value |> max(1) |> min(@max_tail)

  defp tail(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> tail(number)
      _ -> @default_tail
    end
  end

  defp tail(_value), do: @default_tail

  defp truncate(output) when byte_size(output) <= @max_output, do: String.replace_invalid(output)

  defp truncate(output) do
    tail = binary_part(output, byte_size(output) - @max_output, @max_output)
    "…\n" <> String.replace_invalid(tail)
  end
end
