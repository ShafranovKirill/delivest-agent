defmodule DelivestAgent.Shell do
  @behaviour DelivestAgent.Runner

  @impl true
  def cmd(command, args) do
    case System.find_executable(command) do
      nil -> {"#{command}: command not found", 127}
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  end
end
