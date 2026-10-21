defmodule DelivestAgent.FakeRunner do
  @behaviour DelivestAgent.Runner

  def stub(fun), do: Process.put(__MODULE__, fun)

  def stub_global(fun), do: Application.put_env(:delivest_agent, __MODULE__, fun)

  @impl true
  def cmd(command, args) do
    fun = Process.get(__MODULE__) || Application.get_env(:delivest_agent, __MODULE__)
    fun.(command, args)
  end
end
