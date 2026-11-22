defmodule DelivestAgent.CommandJournal do
  @moduledoc "Persists command outcomes across WebSocket reconnects and agent restarts."
  alias DelivestAgent.Config

  def claim(id, action, args) when is_binary(id) and is_binary(action) and is_map(args) do
    if byte_size(id) > 0 and byte_size(id) <= 200 do
      dir = Path.join(Config.get(:data_dir, "/data"), "commands")
      path = Path.join(dir, Base.encode16(:crypto.hash(:sha256, id), case: :lower) <> ".json")

      stable_args = if action == "update", do: Map.drop(args, ["token", "upload_url"]), else: args

      fingerprint =
        Base.encode16(:crypto.hash(:sha256, Jason.encode!(%{action: action, args: stable_args})),
          case: :lower
        )

      document = %{
        "id" => id,
        "action" => action,
        "fingerprint" => fingerprint,
        "state" => "running",
        "started_at" => now()
      }

      with :ok <- File.mkdir_p(dir), :ok <- File.chmod(dir, 0o700) do
        case File.open(path, [:write, :binary, :exclusive]) do
          {:ok, file} ->
            File.chmod(path, 0o600)
            result = IO.binwrite(file, Jason.encode!(document))
            File.close(file)
            if result == :ok, do: {:new, path}, else: {:error, "cannot persist command"}

          {:error, :eexist} ->
            read_existing(path, id, fingerprint)

          {:error, reason} ->
            {:error, "cannot persist command: #{:file.format_error(reason)}"}
        end
      end
    else
      {:error, "invalid command ID"}
    end
  end

  def claim(_, _, _), do: {:error, "invalid command"}

  def finish(path, ok?, output) do
    with {:ok, content} <- File.read(path),
         {:ok, document} <- Jason.decode(content) do
      save(
        path,
        Map.merge(document, %{
          "state" => "complete",
          "ok" => ok?,
          "output" => output,
          "finished_at" => now()
        })
      )
    end
  end

  defp read_existing(path, id, fingerprint) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"id" => ^id, "fingerprint" => ^fingerprint, "state" => "complete"} = result} ->
            {:complete, result}

          {:ok, %{"id" => ^id, "fingerprint" => ^fingerprint, "state" => "running"}} ->
            {:interrupted,
             "command was interrupted; its release attempt will be recovered before a new update"}

          {:ok, _} ->
            {:error, "command ID was already used for different arguments"}

          _ ->
            {:interrupted, "command journal is incomplete; command will not be repeated"}
        end

      _ ->
        {:error, "cannot read command journal"}
    end
  end

  defp save(path, document) do
    temp = path <> ".tmp"

    with :ok <- File.write(temp, Jason.encode!(document), [:sync]),
         :ok <- File.chmod(temp, 0o600),
         :ok <- File.rename(temp, path) do
      :ok
    else
      error ->
        File.rm(temp)
        error
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
