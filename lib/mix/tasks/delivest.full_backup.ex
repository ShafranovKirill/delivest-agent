defmodule Mix.Tasks.Delivest.FullBackup do
  use Mix.Task

  alias DelivestAgent.{FullBackup, Project}

  @shortdoc "Export or import a complete Delivest instance"

  @switches [
    project_dir: :string,
    compose_file: :string,
    project_name: :string,
    replace: :boolean,
    app_stopped: :boolean,
    leave_stopped: :boolean
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    case {args, invalid, opts[:project_dir]} do
      {[action, path], [], dir} when action in ["export", "import"] and is_binary(dir) ->
        project = %Project{
          name: DelivestAgent.FullBackup.CLI.project_name(dir, opts[:project_name]),
          dir: Path.expand(dir),
          files: [Path.expand(opts[:compose_file] || "docker-compose.yml", dir)],
          agent_service: "agent"
        }

        result =
          case action do
            "export" ->
              if opts[:replace],
                do: {:error, {1, "--replace applies only to import"}},
                else: FullBackup.export(project, path, opts)

            "import" ->
              if opts[:leave_stopped],
                do: {:error, {1, "--leave-stopped applies only to export"}},
                else: FullBackup.import(project, path, opts)
          end

        case result do
          {:ok, message} -> Mix.shell().info(message)
          {:error, {_, message}} -> Mix.raise(message)
          {:error, message} -> Mix.raise(message)
        end

      _ ->
        Mix.raise(
          "usage: mix delivest.full_backup export|import PATH --project-dir ROOT [--compose-file FILE] [--project-name NAME] [--app-stopped] [--leave-stopped|--replace]"
        )
    end
  end
end
