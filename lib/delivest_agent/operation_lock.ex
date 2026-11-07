defmodule DelivestAgent.OperationLock do
  @moduledoc false

  @ready "DELIVEST_LOCK_READY\n"
  @holder "printf 'DELIVEST_LOCK_READY\\n'; read ignored"

  def with_lock(project, fun) when is_function(fun, 0) do
    path = Path.join(project.dir, ".delivest-operation.lock")
    key = {__MODULE__, path}

    if Process.get(key) do
      fun.()
    else
      case acquire(path) do
        {:ok, port} ->
          Process.put(key, true)

          try do
            fun.()
          after
            Process.delete(key)
            release(port)
          end

        {:error, message} ->
          {:error, {1, message}}
      end
    end
  end

  defp acquire(path) do
    with :ok <- valid_lock_path(path),
         executable when is_binary(executable) <- System.find_executable("flock") do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          args: ["-n", "-E", "75", "--", path, "sh", "-c", @holder]
        ])

      await_holder(port, path, "")
    else
      nil -> {:error, "cannot lock project: flock is unavailable"}
      {:error, :busy} -> {:error, "project operation is busy; lock at #{path}"}
      {:error, reason} -> {:error, "cannot lock project: #{inspect(reason)}"}
    end
  end

  defp valid_lock_path(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular}} -> :ok
      {:ok, _} -> {:error, :busy}
      error -> error
    end
  end

  defp await_holder(port, path, output) do
    receive do
      {^port, {:data, data}} ->
        bytes = output <> data

        if String.starts_with?(bytes, @ready) do
          {:ok, port}
        else
          await_holder(port, path, bytes)
        end

      {^port, {:exit_status, 75}} ->
        {:error, "project operation is busy; lock at #{path}"}

      {^port, {:exit_status, code}} ->
        {:error, "cannot lock project: flock exited with status #{code}: #{output}"}
    after
      5_000 ->
        Port.close(port)
        {:error, "cannot lock project: flock timed out"}
    end
  end

  defp release(port) do
    Port.command(port, "\n")

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      5_000 -> Port.close(port)
    end
  end
end
