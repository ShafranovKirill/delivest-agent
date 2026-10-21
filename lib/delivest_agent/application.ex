defmodule DelivestAgent.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [{Task.Supervisor, name: DelivestAgent.TaskSupervisor}] ++ bastion_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: DelivestAgent.Supervisor)
  end

  defp bastion_children do
    config = DelivestAgent.Config.bastion()

    cond do
      not Application.get_env(:delivest_agent, :start_bastion, true) ->
        []

      config ->
        [{DelivestAgent.Bastion, config}]

      true ->
        Logger.warning("BASTION_URL or BASTION_TOKEN is not set, the agent stays idle")
        []
    end
  end
end
