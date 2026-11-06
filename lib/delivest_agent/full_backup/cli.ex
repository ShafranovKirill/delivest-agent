defmodule DelivestAgent.FullBackup.CLI do
  @moduledoc false

  alias DelivestAgent.{FullBackup, Project}

  def project_name(dir, explicit \\ nil) do
    case explicit || env_project_name(dir) do
      name when is_binary(name) and name != "" -> name
      _ -> Path.basename(Path.expand(dir))
    end
  end

  defp env_project_name(dir) do
    path = Path.join(dir, ".env")

    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.find_value(fn line ->
        case Regex.run(~r/^\s*COMPOSE_PROJECT_NAME\s*=\s*(.*?)\s*$/, line) do
          [_, value] -> value |> String.trim() |> String.trim("\"") |> String.trim("'")
          _ -> nil
        end
      end)
    end
  end

  def eval_json(json) do
    result = with {:ok, args} <- Jason.decode(json), do: run(args)

    case result do
      {:ok, message} ->
        IO.puts(message)

      {:error, {_, message}} ->
        IO.puts(:stderr, message)
        System.halt(1)

      _ ->
        IO.puts(:stderr, "invalid full backup arguments")
        System.halt(1)
    end
  end

  def run(%{"action" => action, "path" => path, "project_dir" => dir} = args)
      when action in ["export", "import"] and is_binary(path) and is_binary(dir) do
    project = %Project{
      name: project_name(dir, args["project_name"]),
      dir: Path.expand(dir),
      files: [Path.expand(args["compose_file"] || "docker-compose.yml", dir)],
      agent_service: "agent"
    }

    case action do
      "export" ->
        FullBackup.export(project, path,
          app_stopped: args["app_stopped"] == true,
          leave_stopped: args["leave_stopped"] == true
        )

      "import" ->
        FullBackup.import(project, path,
          replace: args["replace"] == true,
          app_stopped: args["app_stopped"] == true
        )
    end
  end

  def run(_), do: {:error, {1, "invalid full backup arguments"}}
end
