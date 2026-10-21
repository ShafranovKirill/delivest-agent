defmodule DelivestAgent.Compose do
  alias DelivestAgent.{Project, Runner}

  def services(%Project{} = project) do
    case run(project, ["config", "--services"]) do
      {:ok, output} ->
        {:ok,
         output
         |> String.split("\n", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == project.agent_service))}

      error ->
        error
    end
  end

  def containers(%Project{} = project) do
    with {:ok, output} <- run(project, ["ps", "--all", "--format", "json"]) do
      {:ok, output |> decode_lines() |> Enum.reject(&(&1["Service"] == project.agent_service))}
    end
  end

  def pull(project, services), do: run(project, ["pull" | services])
  def up(project, services), do: run(project, ["up", "--detach" | services])
  def stop(project, services), do: run(project, ["stop" | services])
  def restart(project, services), do: run(project, ["restart" | services])

  def logs(project, services, tail),
    do: run(project, ["logs", "--no-color", "--tail", to_string(tail) | services])

  def run(project, args) do
    case Runner.cmd("docker", Project.compose_args(project, args)) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  end

  defp decode_lines(output) do
    output
    |> String.trim()
    |> case do
      "[" <> _ = array -> Jason.decode!(array)
      lines -> lines |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end
  end
end
