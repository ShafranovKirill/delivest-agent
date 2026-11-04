defmodule DelivestAgent.Commands do
  alias DelivestAgent.{Backup, Compose, Env, Project, Release, Runner, Status}

  @actions ~w(status update rollback agent_update start stop restart logs env_read env_write backup restore)
  @max_output 64_000
  @default_tail 200
  @max_tail 2_000

  def actions, do: @actions

  def run(action, args \\ %{}, project_result \\ Project.discover())

  def run("status", _args, project_result), do: {:ok, Status.collect(project_result)}

  def run("env_read", _args, {:ok, %Project{} = project}), do: Env.read(project)

  def run("rollback", args, {:ok, %Project{} = project}) do
    "rollback"
    |> execute(args, project, [])
    |> format()
    |> command_result()
  end

  def run(action, args, {:ok, %Project{} = project}) when action in @actions do
    with {:ok, services} <- Compose.services(project) do
      action |> execute(args, project, services) |> format()
    end
    |> command_result()
  end

  def run(action, _args, {:error, reason}) when action in @actions,
    do: {:error, "compose project is not available: #{inspect(reason)}"}

  def run(action, _args, _project_result), do: {:error, "unknown action: #{action}"}

  defp command_result({:ok, output}), do: {:ok, output}
  defp command_result({:error, {_status, output}}), do: {:error, truncate(output)}
  defp command_result({:error, output}) when is_binary(output), do: {:error, truncate(output)}

  # A failed pull leaves the site as it was. Once the new containers are up, a site that
  # does not answer, or answers from an old container, brings back the confirmed
  # release. The confirmed and previous releases are never overwritten by an attempt.
  defp execute("update", args, project, _services) do
    case Release.begin_update(project) do
      {:ok, state, begin_log} ->
        case steps([
               {"backup before update", fn -> backup_before_update(project, args) end},
               {"git pull", fn -> git_pull(project.dir) end}
             ]) do
          {:ok, log} ->
            case prepare_images(project, state) do
              {:ok, definitions, pull_log, target} ->
                start_update(project, state, begin_log <> log <> pull_log, definitions, target)

              {:error, prepare_log} ->
                {:error, begin_log <> log <> prepare_log}
            end

          {:error, log} ->
            prepare_failed(project, state, begin_log <> log)

          error ->
            error
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp execute("rollback", _args, project, _services) do
    case Release.manual_target() do
      {:ok, release} ->
        case rollback(project, release, "rollback") do
          {:ok, log} ->
            case Release.swap_after_rollback() do
              :ok ->
                {:ok, log}

              {:error, message} ->
                {:ok, log <> "== save the rollback result failed\n" <> message <> "\n"}
            end

          error ->
            error
        end

      {:error, {_status, message}} ->
        {:error, message}
    end
  end

  defp execute("agent_update", _args, project, _services) do
    steps([
      {"docker compose pull #{project.agent_service}",
       fn -> Compose.pull(project, [project.agent_service]) end},
      {"recreate the agent", fn -> Release.start_agent_updater(project) end}
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

  defp prepare_images(project, state) do
    case Compose.definitions(project) do
      {:ok, definitions} ->
        case pull_images(project, definitions) do
          {:ok, pull_log} ->
            case Release.record_attempt(project, definitions) do
              {:ok, target} ->
                {:ok, definitions, pull_log, target}

              {:error, message} ->
                prepare_failed(
                  project,
                  state,
                  "== remember the target release failed\n#{message}\n"
                )
            end

          {:error, pull_log} ->
            prepare_failed(project, state, pull_log)
        end

      {:error, {_status, output}} ->
        prepare_failed(project, state, section("read the compose services failed", output))
    end
  end

  # A pull that did not finish leaves the checkout on the new revision while the
  # containers still run the confirmed release. Returning git to the confirmed
  # revision makes the next attempt start from the same point as a rollback.
  defp prepare_failed(project, state, log) do
    git = (state["current"] || %{})["git"]

    case git_reset(project.dir, git) do
      {:ok, output} -> {:error, log <> section("git reset", output)}
      {:skip, reason} -> {:error, log <> section("git reset", "skipped: #{reason}")}
      {:error, {_status, output}} -> {:error, log <> section("git reset failed", output)}
    end
  end

  defp start_update(project, state, log, definitions, target) do
    services = Enum.map(definitions, & &1.name)

    started =
      steps([
        {"docker compose up", fn -> Compose.up_prepared(project, services) end},
        {"gateway restart", fn -> restart_gateway(project, services) end},
        {"wait until the site answers", fn -> Release.wait_healthy(project, target) end}
      ])

    case started do
      {:ok, started_log} ->
        case Release.confirm(project) do
          {:ok, confirm_log} ->
            {:ok, pruned} = steps([{"docker image prune", fn -> prune_images() end}])
            {:ok, log <> started_log <> section("confirm the release", confirm_log) <> pruned}

          {:error, message} ->
            {:error, log <> started_log <> section("confirm the release failed", message)}
        end

      {:error, started_log} ->
        rollback_log =
          case rollback(project, state["current"], "automatic rollback") do
            {:ok, output} -> output
            {:error, {_status, output}} -> output
            {:error, output} -> output
          end

        {:error, log <> started_log <> rollback_log}
    end
  end

  # The rollback reads the Compose file of the release it restores, so a service
  # that was added, removed or renamed between revisions is handled correctly.
  defp rollback(_project, nil, title),
    do: {:error, {1, section(title <> " failed", "no confirmed release to roll back to")}}

  defp rollback(project, release, title) do
    with {:ok, schema_log} <-
           rollback_step("check database migration safety", fn ->
             Release.guard_rollback(project, release)
           end),
         {:ok, git_log} <-
           rollback_step("git reset", fn -> git_reset(project.dir, release["git"]) end),
         {:ok, definitions, definitions_log} <- rollback_definitions(project),
         {:ok, restore_log} <-
           rollback_step("restore previous images", fn ->
             Release.restore(project, release, definitions)
           end) do
      services = Enum.map(definitions, & &1.name)
      target = Release.target(release, definitions)

      result =
        steps([
          {"docker compose up", fn -> Compose.up_prepared(project, services) end},
          {"gateway restart", fn -> restart_gateway(project, services) end},
          {"wait until the site answers",
           fn ->
             Release.wait_healthy(project, target)
           end}
        ])

      head = section(title, "restored #{release["git"] || release["at"]}")
      prefix = head <> schema_log <> git_log <> definitions_log <> restore_log

      case result do
        {:ok, log} -> {:ok, prefix <> log}
        {:error, {_status, log}} -> {:error, {1, prefix <> log}}
        {:error, log} when is_binary(log) -> {:error, {1, prefix <> log}}
      end
    else
      {:error, {_status, log}} -> {:error, {1, log}}
    end
  end

  defp rollback_definitions(project) do
    case Compose.definitions(project) do
      {:ok, definitions} ->
        names = Enum.map_join(definitions, ", ", & &1.name)
        {:ok, definitions, section("read the restored compose services", names)}

      {:error, {_status, output}} ->
        {:error, {1, section("read the restored compose services failed", output)}}
    end
  end

  defp rollback_step(title, fun) do
    case fun.() do
      {:ok, output} -> {:ok, section(title, output)}
      {:skip, reason} -> {:ok, section(title, "skipped: #{reason}")}
      {:error, {_status, output}} -> {:error, {1, section(title <> " failed", output)}}
    end
  end

  defp backup_before_update(project, %{"upload_url" => _} = args) do
    with {:ok, dumped} <- Backup.dump(project),
         {:ok, _uploaded} <- Backup.upload(args) do
      {:ok, dumped <> ", uploaded to the bastion"}
    end
  after
    Backup.cleanup()
  end

  defp backup_before_update(_project, _args), do: {:skip, "the bastion did not ask for it"}

  defp stop(_project, []), do: {:skip, "no server service"}
  defp stop(project, services), do: Compose.stop(project, services)

  defp start(_project, []), do: {:skip, "no server service"}
  defp start(project, services), do: Compose.up(project, services)

  defp combine({:ok, first}, {:ok, second}), do: {:ok, first <> second}
  defp combine({_, first}, {_, second}), do: {:error, text(first) <> text(second)}

  defp text({_status, output}), do: output
  defp text(output), do: output

  defp pull_images(project, definitions) do
    steps(
      Enum.map(definitions, fn definition ->
        {"pull #{definition.name}", fn -> Compose.prepare_image(project, definition) end}
      end)
    )
  end

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
        {output, status} -> {:error, {status, output}}
      end
    else
      {:skip, "not a git checkout"}
    end
  end

  defp git_reset(_dir, nil), do: {:skip, "no git revision was remembered"}

  defp git_reset(dir, sha) do
    {command, args} = as_owner(dir, ["git", "-C", dir, "reset", "--keep", sha])

    case Runner.cmd(command, args) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
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
