defmodule DelivestAgent.Release do
  @moduledoc """
  Remembers the images and the git revision before an update, so the deployment can go
  back to them, and waits for the site to answer after it.
  """

  alias DelivestAgent.{Compose, Config, Project, Runner, Status}

  @previous_tag "delivest-previous"

  def state_path, do: Path.join(Config.get(:data_dir, "/data"), "rollback.json")

  def rollback_info do
    case read_state() do
      {:ok, state} -> Map.take(state, ["at", "git"])
      _ -> nil
    end
  end

  # The running images get a second tag, so pulling the new ones does not leave them
  # dangling and `docker image prune` keeps them for a rollback.
  def remember(%Project{} = project) do
    with {:ok, containers} <- Compose.containers(project),
         {:ok, images} <- running_images(Enum.map(containers, & &1["ID"])),
         :ok <- tag_previous(images) do
      state = %{
        "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "git" => git_head(project.dir),
        "images" => Enum.map(images, fn {ref, id} -> %{"ref" => ref, "id" => id} end)
      }

      File.mkdir_p!(Path.dirname(state_path()))
      File.write!(state_path(), Jason.encode!(state))

      {:ok,
       "remembered #{length(images)} images#{if state["git"], do: " and git #{state["git"]}"}"}
    end
  end

  def read_state do
    with {:ok, content} <- File.read(state_path()),
         {:ok, %{"images" => images} = state} when is_list(images) <- Jason.decode(content) do
      {:ok, state}
    else
      _ -> {:error, {1, "nothing to roll back to: the agent has not updated this site yet"}}
    end
  end

  def restore_images(%{"images" => images}) do
    Enum.reduce_while(images, {:ok, ""}, fn %{"ref" => ref}, {:ok, log} ->
      case Runner.cmd("docker", ["tag", previous_ref(ref), ref]) do
        {_output, 0} -> {:cont, {:ok, log <> "#{ref} <- #{previous_ref(ref)}\n"}}
        {output, status} -> {:halt, {:error, {status, log <> output}}}
      end
    end)
  end

  def previous_ref(ref) do
    ref = ref |> String.split("@") |> hd()
    {path, name} = split_last(ref, "/")
    repo = name |> String.split(":") |> hd()
    path <> repo <> ":" <> @previous_tag
  end

  defp split_last(ref, separator) do
    case String.split(ref, separator) do
      [name] -> {"", name}
      parts -> {Enum.join(Enum.drop(parts, -1), separator) <> separator, List.last(parts)}
    end
  end

  def wait_healthy(%Project{} = project) do
    timeout = Config.get(:health_timeout_ms, 300_000)
    poll = Config.get(:health_poll_ms, 5_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    started = System.monotonic_time(:millisecond)

    case wait(project, deadline, poll, 0) do
      :ok ->
        {:ok, "healthy after #{div(System.monotonic_time(:millisecond) - started, 1000)} s"}

      {:error, problems} ->
        {:error,
         {1,
          "not healthy after #{div(timeout, 1000)} s:\n" <>
            Enum.map_join(problems, "\n", &("- " <> &1))}}
    end
  end

  # Two good answers in a row, so a server that is still booting is not taken for a live one.
  defp wait(project, deadline, poll, streak) do
    problems = problems(project)
    streak = if problems == [], do: streak + 1, else: 0

    cond do
      streak >= 2 ->
        :ok

      System.monotonic_time(:millisecond) + poll > deadline ->
        {:error, if(problems == [], do: ["the site answered only once"], else: problems)}

      true ->
        Process.sleep(poll)
        wait(project, deadline, poll, streak)
    end
  end

  def problems(project) do
    containers =
      Enum.flat_map(Status.containers(project), fn
        %{"error" => error} -> [error]
        %{"state" => "running"} -> []
        %{"service" => service, "state" => state} -> ["container #{service} is #{state}"]
      end)

    checks =
      for {kind, %{"ok" => false} = check} <- Status.checks(),
          do: "#{kind} does not answer: #{check["status"] || check["error"]}"

    containers ++ checks
  end

  # The agent cannot recreate its own container, so a short-lived helper from the new
  # agent image does it a few seconds after the command result has been sent.
  def start_agent_updater(%Project{} = project) do
    with {:ok, image} <- agent_image(project) do
      name = "#{project.name}_agent_updater"
      Runner.cmd("docker", ["rm", "--force", name])

      compose =
        Project.compose_args(project, [
          "up",
          "--detach",
          "--force-recreate",
          "--no-deps",
          project.agent_service
        ])

      args =
        ["run", "--detach", "--rm", "--name", name] ++
          ["--volume", "/var/run/docker.sock:/var/run/docker.sock"] ++
          ["--volume", "#{project.dir}:#{project.dir}", "--workdir", project.dir] ++
          ["--env", "PWD=#{project.dir}"] ++
          ["--entrypoint", "sh", image, "-c", ~S(sleep 5 && exec docker "$@"), "sh" | compose]

      case Runner.cmd("docker", args) do
        {_output, 0} -> {:ok, "the agent restarts with #{image} in a few seconds"}
        {output, status} -> {:error, {status, output}}
      end
    end
  end

  defp agent_image(project) do
    with {:ok, containers} <- Compose.ps(project) do
      case Enum.find(containers, &(&1["Service"] == project.agent_service)) do
        %{"Image" => image} when is_binary(image) -> {:ok, image}
        _ -> {:error, {1, "the agent container is not found"}}
      end
    end
  end

  defp running_images([]), do: {:error, {1, "no containers to remember"}}

  defp running_images(ids) do
    case Runner.cmd("docker", ["inspect", "--format", "{{.Config.Image}} {{.Image}}" | ids]) do
      {output, 0} ->
        images =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, " ") do
              [ref, id] -> [{ref, id}]
              _ -> []
            end
          end)
          |> Enum.uniq()

        {:ok, images}

      {output, status} ->
        {:error, {status, output}}
    end
  end

  defp tag_previous(images) do
    Enum.reduce_while(images, :ok, fn {ref, id}, :ok ->
      case Runner.cmd("docker", ["tag", id, previous_ref(ref)]) do
        {_output, 0} -> {:cont, :ok}
        {output, status} -> {:halt, {:error, {status, output}}}
      end
    end)
  end

  defp git_head(dir) do
    with true <- File.exists?(Path.join(dir, ".git")),
         {sha, 0} <- Runner.cmd("git", ["-C", dir, "rev-parse", "HEAD"]) do
      String.trim(sha)
    else
      _ -> nil
    end
  end
end
