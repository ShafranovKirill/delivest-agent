defmodule DelivestAgent.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    DelivestAgent.Metrics.init()

    children =
      [{Task.Supervisor, name: DelivestAgent.TaskSupervisor}] ++
        backup_job_children() ++ bastion_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: DelivestAgent.Supervisor)
  end

  defp backup_job_children do
    case Application.get_env(:delivest_agent, :instance_backup_dir) ||
           System.get_env("INSTANCE_BACKUP_DIR") do
      dir when is_binary(dir) and dir != "" -> [{DelivestAgent.BackupJobs, dir: dir}]
      _ -> []
    end
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
