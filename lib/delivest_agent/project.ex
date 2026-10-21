defmodule DelivestAgent.Project do
  alias DelivestAgent.Runner

  @enforce_keys [:name, :dir, :files, :agent_service]
  defstruct [:name, :dir, :files, :agent_service]

  @labels %{
    name: "com.docker.compose.project",
    dir: "com.docker.compose.project.working_dir",
    files: "com.docker.compose.project.config_files",
    agent_service: "com.docker.compose.service"
  }

  def discover(container \\ hostname()) do
    with {output, 0} <-
           Runner.cmd("docker", ["inspect", "--format", "{{json .Config.Labels}}", container]),
         {:ok, labels} when is_map(labels) <- Jason.decode(output),
         %{name: name, dir: dir, files: files, agent_service: service}
         when is_binary(name) and is_binary(dir) and is_binary(files) <-
           Map.new(@labels, fn {key, label} -> {key, labels[label]} end),
         true <- File.dir?(dir) do
      {:ok,
       %__MODULE__{name: name, dir: dir, files: String.split(files, ","), agent_service: service}}
    else
      false -> {:error, :project_dir_not_mounted}
      {output, status} when is_integer(status) -> {:error, {:inspect_failed, String.trim(output)}}
      _ -> {:error, :not_a_compose_container}
    end
  end

  def compose_args(%__MODULE__{} = project, args) do
    ["compose", "-p", project.name, "--project-directory", project.dir] ++
      Enum.flat_map(project.files, &["-f", &1]) ++ args
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "localhost"
    end
  end
end
