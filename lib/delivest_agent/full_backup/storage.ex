defmodule DelivestAgent.FullBackup.Storage do
  @moduledoc false

  @raft_paths ~w(log conf snapshot state)
  @max_mirror_bytes 1_048_576

  # A SeaweedFS 4.50 snapshot keeps volume IDs and the topology ID in this mirror.
  # Raft membership contains the source server address, so discard only that
  # membership from the extracted copy and let the target master rejoin at its IP.
  def prepare(work) do
    master = Path.join([work, "data", "m9333"])
    mirror = Path.join(master, "max_volume_id")

    with {:ok, %{type: :regular, size: size}} when size <= @max_mirror_bytes <-
           File.lstat(mirror),
         {:ok, bytes} <- File.read(mirror),
         {:ok, data} <- Jason.decode(bytes),
         :ok <- validate_mirror(data),
         :ok <- remove_raft(master) do
      :ok
    else
      {:error, {1, _}} = error ->
        error

      _ ->
        {:error,
         {1,
          "SeaweedFS master mirror m9333/max_volume_id is missing or incomplete; storage was not changed"}}
    end
  end

  defp validate_mirror(%{
         "maxVolumeId" => max_id,
         "topologyId" => topology,
         "growthFrozen" => frozen
       })
       when is_integer(max_id) and max_id >= 0 and is_binary(topology) and
              is_boolean(frozen) do
    if String.trim(topology) != "", do: :ok, else: {:error, :invalid_mirror}
  end

  defp validate_mirror(_), do: {:error, :invalid_mirror}

  defp remove_raft(master) do
    Enum.reduce_while(@raft_paths, :ok, fn name, :ok ->
      case File.rm_rf(Path.join(master, name)) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, reason, path} ->
          {:halt,
           {:error,
            {1, "cannot remove extracted Raft state #{path}: #{:file.format_error(reason)}"}}}
      end
    end)
  end
end
