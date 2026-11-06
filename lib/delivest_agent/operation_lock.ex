defmodule DelivestAgent.OperationLock do
  @moduledoc false

  def with_lock(project, fun) when is_function(fun, 0) do
    path = Path.join(project.dir, ".delivest-operation.lock")
    key = {__MODULE__, path}

    if Process.get(key) do
      fun.()
    else
      case File.mkdir(path) do
        :ok ->
          Process.put(key, true)

          try do
            fun.()
          after
            Process.delete(key)
            File.rmdir(path)
          end

        {:error, :eexist} ->
          {:error, {1, "project operation is busy; lock at #{path}"}}

        {:error, reason} ->
          {:error, {1, "cannot lock project: #{:file.format_error(reason)}"}}
      end
    end
  end
end
