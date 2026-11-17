defmodule DelivestAgent.BackupMonitor do
  @moduledoc false

  @token ~r/\A[0-9a-f]{64}\z/
  @steps ~w(accepted quiescing validating_archive checking_compatibility preparing_storage staging_database replacing_storage replacing_database exporting restarting checking_readiness ready)
  @phases ~w(queued waiting running complete failed interrupted)

  def publish(job_dir, status) do
    with dir when is_binary(dir) and dir != "" <- System.get_env("INSTANCE_BACKUP_MONITOR_DIR"),
         token_path <- Path.join(job_dir, "monitor.token"),
         {:ok, %{type: :regular}} <- File.lstat(token_path),
         {:ok, token} <- File.read(token_path),
         token <- String.trim(token),
         true <- Regex.match?(@token, token) do
      payload = %{
        action: allow(status[:action], ~w(import export), "unknown"),
        phase: allow(status[:phase], @phases, "failed"),
        step: allow(status[:step], @steps, "accepted"),
        steps: safe_steps(status[:steps]),
        safe_to_resume: status[:safe_to_resume] == true,
        updated_at: status[:updated_at],
        reason_code: reason_code(status)
      }

      write_json(Path.join(dir, token <> ".json"), payload)
    else
      _ -> :ok
    end
  end

  def heartbeat(dir) do
    case System.get_env("INSTANCE_BACKUP_MONITOR_DIR") do
      monitor when is_binary(monitor) and monitor != "" and is_binary(dir) ->
        write_json(Path.join(monitor, "heartbeat.json"), %{updated_at: now()})

      _ ->
        :ok
    end
  end

  defp safe_steps(steps) when is_list(steps) do
    for item <- steps,
        is_map(item),
        step = item[:step] || item["step"],
        at = item[:updated_at] || item["updated_at"],
        step in @steps,
        is_binary(at),
        do: %{step: step, updated_at: at}
  end

  defp safe_steps(_), do: []

  defp reason_code(%{phase: phase}) when phase != "failed" and phase != "interrupted", do: nil

  defp reason_code(%{message: message} = status) when is_binary(message) do
    cond do
      String.contains?(message, "ROLLBACK FAILED") -> "unsafe_restore"
      String.contains?(message, "uncertain") -> "unsafe_restore"
      String.contains?(message, "schema_migrations") -> "migration_mismatch"
      String.contains?(message, "manifest") -> "archive_integrity"
      String.contains?(message, "SHA256") -> "archive_integrity"
      String.contains?(message, "trailing tar data") -> "archive_integrity"
      String.contains?(message, "invalid tar") -> "archive_integrity"
      String.contains?(message, "storage.tar") -> "archive_integrity"
      String.contains?(message, "database.dump") -> "archive_integrity"
      String.contains?(message, "did not become ready") -> "readiness_failed"
      status[:safe_to_resume] == false -> "unsafe_restore"
      true -> "generic_failure"
    end
  end

  defp reason_code(_), do: "generic_failure"

  defp allow(value, values, fallback), do: if(value in values, do: value, else: fallback)

  defp write_json(path, payload) do
    temp = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(temp, Jason.encode!(payload), [:binary]),
         :ok <- File.chmod(temp, 0o644),
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
