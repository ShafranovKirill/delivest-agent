defmodule DelivestAgent.Bastion do
  use Slipstream, restart: :permanent

  require Logger

  alias DelivestAgent.{Commands, Config, Identity, Project, Status}

  @command_timeout :timer.minutes(40)

  def start_link(config), do: Slipstream.start_link(__MODULE__, config, name: __MODULE__)

  def socket_uri(url, token, instance_id) do
    uri = URI.parse(String.trim_trailing(url, "/"))
    query = URI.encode_query(%{"token" => token, "instance_id" => instance_id})
    %{uri | path: (uri.path || "") <> "/agent/websocket", query: query} |> URI.to_string()
  end

  @impl Slipstream
  def init(%{url: url, token: token}) do
    instance_id = Identity.instance_id()

    socket =
      new_socket()
      |> assign(
        instance_id: instance_id,
        topic: "instance:" <> instance_id,
        running: nil,
        tasks: %{},
        pending: []
      )

    Logger.info("connecting to bastion #{url} as #{instance_id}")

    {:ok,
     connect!(socket,
       uri: socket_uri(url, token, instance_id),
       reconnect_after_msec: [1_000, 2_000, 5_000, 10_000, 30_000],
       rejoin_after_msec: [1_000, 5_000, 30_000],
       test_mode?: Config.get(:bastion_test_mode, false)
     )}
  end

  @impl Slipstream
  def handle_connect(socket) do
    {:ok, join(socket, socket.assigns.topic, info())}
  end

  @impl Slipstream
  def handle_join(_topic, _reply, socket) do
    Logger.info("joined bastion")
    {:ok, socket |> flush_pending() |> schedule_heartbeat(0)}
  end

  @impl Slipstream
  def handle_message(topic, "command", %{"id" => id, "action" => action} = payload, socket)
      when topic == socket.assigns.topic do
    cond do
      socket.assigns.running ->
        {:ok, reply(socket, id, false, "busy: another command is running")}

      action not in Commands.actions() ->
        {:ok, reply(socket, id, false, "unknown action: #{action}")}

      true ->
        Logger.info("running #{action} (#{id})")
        push(socket, socket.assigns.topic, "command_started", %{"id" => id})
        args = Map.get(payload, "args") || %{}
        task = start_task(fn -> Commands.run(action, args) end)
        timer = Process.send_after(self(), {:command_timeout, task.ref}, @command_timeout)

        {:ok,
         socket
         |> assign(running: %{id: id, action: action, task: task, timer: timer})
         |> track(task, {:command, id})}
    end
  end

  def handle_message(_topic, event, _payload, socket) do
    Logger.debug("ignored bastion event #{event}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_info(:heartbeat, socket) do
    if :heartbeat in Map.values(socket.assigns.tasks),
      do: {:noreply, socket},
      else: {:noreply, start_heartbeat(socket)}
  end

  def handle_info({ref, result}, socket) when is_map_key(socket.assigns.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {kind, socket} = untrack(socket, ref)
    {:noreply, finish(kind, result, socket)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when is_map_key(socket.assigns.tasks, ref) do
    {kind, socket} = untrack(socket, ref)
    {:noreply, finish(kind, {:error, "agent task crashed: #{inspect(reason)}"}, socket)}
  end

  def handle_info({:command_timeout, ref}, %{assigns: %{running: %{task: %{ref: ref}}}} = socket) do
    Task.Supervisor.terminate_child(DelivestAgent.TaskSupervisor, socket.assigns.running.task.pid)
    {kind, socket} = untrack(socket, ref)
    {:noreply, finish(kind, {:error, "command timed out"}, socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("bastion disconnected: #{inspect(reason)}")
    reconnect(socket)
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    Logger.warning("bastion closed #{topic}: #{inspect(reason)}")
    rejoin(socket, topic, info())
  end

  defp finish({:command, id}, result, socket) do
    Process.cancel_timer(socket.assigns.running.timer)

    socket =
      case result do
        {:ok, output} -> reply(socket, id, true, output)
        {:error, output} -> reply(socket, id, false, output)
      end

    socket |> assign(running: nil) |> schedule_heartbeat(0)
  end

  defp finish(:heartbeat, %{} = status, socket) do
    status = Map.put(status, "running", running(socket))
    push(socket, socket.assigns.topic, "heartbeat", status)
    schedule_heartbeat(socket, Config.get(:heartbeat_ms, 30_000))
  end

  defp finish(:heartbeat, _error, socket),
    do: schedule_heartbeat(socket, Config.get(:heartbeat_ms, 30_000))

  defp reply(socket, id, ok?, output) do
    result = %{"id" => id, "ok" => ok?, "output" => output}

    case push(socket, socket.assigns.topic, "command_result", result) do
      {:ok, _ref} -> socket
      {:error, _reason} -> assign(socket, pending: socket.assigns.pending ++ [result])
    end
  end

  defp flush_pending(socket) do
    {sent, left} =
      Enum.split_with(socket.assigns.pending, fn result ->
        match?({:ok, _ref}, push(socket, socket.assigns.topic, "command_result", result))
      end)

    if sent != [], do: Logger.info("sent #{length(sent)} delayed command results")
    assign(socket, pending: left)
  end

  defp start_heartbeat(socket) do
    task = start_task(fn -> Status.collect(Project.discover()) end)
    track(socket, task, :heartbeat)
  end

  defp running(%{assigns: %{running: %{id: id, action: action}}}),
    do: %{"id" => id, "action" => action}

  defp running(_socket), do: nil

  defp info do
    %{
      "name" => Config.get(:instance_name) || Config.hosts()["api"],
      "hosts" => Config.hosts(),
      "agent_version" => Config.version(),
      "actions" => Commands.actions()
    }
  end

  defp start_task(fun), do: Task.Supervisor.async_nolink(DelivestAgent.TaskSupervisor, fun)

  defp track(socket, task, kind),
    do: assign(socket, tasks: Map.put(socket.assigns.tasks, task.ref, kind))

  defp untrack(socket, ref) do
    {kind, tasks} = Map.pop(socket.assigns.tasks, ref)
    {kind, assign(socket, tasks: tasks)}
  end

  defp schedule_heartbeat(%{assigns: %{heartbeat: timer}} = socket, delay)
       when is_reference(timer) do
    Process.cancel_timer(timer)
    schedule_heartbeat(%{socket | assigns: Map.delete(socket.assigns, :heartbeat)}, delay)
  end

  defp schedule_heartbeat(socket, delay),
    do: assign(socket, heartbeat: Process.send_after(self(), :heartbeat, delay))
end
