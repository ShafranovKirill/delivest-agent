defmodule DelivestAgent.BackupMonitorTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias DelivestAgent.BackupMonitor

  setup do
    root =
      Path.join(System.tmp_dir!(), "backup-monitor-test-#{System.unique_integer([:positive])}")

    job = Path.join(root, "private-job")
    monitor = Path.join(root, "public-monitor")
    File.mkdir_p!(job)
    File.mkdir_p!(monitor)
    token = String.duplicate("a", 64)
    File.write!(Path.join(job, "monitor.token"), token)
    System.put_env("INSTANCE_BACKUP_MONITOR_DIR", monitor)

    on_exit(fn ->
      System.delete_env("INSTANCE_BACKUP_MONITOR_DIR")
      File.rm_rf!(root)
    end)

    %{job: job, monitor: monitor, token: token}
  end

  test "public status contains only allowed fields and a safe reason", ctx do
    status = %{
      id: "secret-job-id",
      action: "import",
      phase: "failed",
      step: "staging_database",
      steps: [%{step: "accepted", updated_at: "2026-01-01T00:00:00Z"}],
      safe_to_resume: false,
      updated_at: "2026-01-01T00:00:01Z",
      message: "staging schema_migrations differ from backup manifest /private/path secret"
    }

    assert :ok = BackupMonitor.publish(ctx.job, status)
    path = Path.join(ctx.monitor, ctx.token <> ".json")
    public = path |> File.read!() |> Jason.decode!()

    assert Map.keys(public) |> Enum.sort() ==
             ~w(action failed_step phase reason_code safe_to_resume step steps updated_at)

    assert public["reason_code"] == "migration_mismatch"
    assert public["steps"] == [%{"step" => "accepted", "updated_at" => "2026-01-01T00:00:00Z"}]
    refute File.read!(path) =~ "secret"
    assert (File.stat!(path).mode &&& 0o777) == 0o644
  end

  test "invalid token and arbitrary status text never become public", ctx do
    File.write!(Path.join(ctx.job, "monitor.token"), "../escape")
    assert :ok = BackupMonitor.publish(ctx.job, %{phase: "failed", message: "private"})
    refute File.exists?(Path.join(ctx.monitor, "escape.json"))
    File.write!(Path.join(ctx.job, "monitor.token"), ctx.token)

    assert :ok =
             BackupMonitor.publish(ctx.job, %{
               action: "private",
               phase: "failed",
               step: "/private/path",
               steps: [],
               message: "private",
               updated_at: "2026-01-01T00:00:00Z"
             })

    public = Path.join(ctx.monitor, ctx.token <> ".json") |> File.read!() |> Jason.decode!()
    assert public["reason_code"] == "generic_failure"
    assert public["step"] == "accepted"
    refute File.read!(Path.join(ctx.monitor, ctx.token <> ".json")) =~ "private"

    assert :ok =
             BackupMonitor.publish(ctx.job, %{
               action: "import",
               phase: "failed",
               step: "restarting",
               steps: [],
               safe_to_resume: false,
               message: "cannot restart server",
               updated_at: "2026-01-01T00:00:01Z"
             })

    public = Path.join(ctx.monitor, ctx.token <> ".json") |> File.read!() |> Jason.decode!()
    assert public["reason_code"] == "unsafe_restore"
  end

  test "heartbeat exposes only update time", ctx do
    assert :ok = BackupMonitor.heartbeat(ctx.job)

    assert %{"updated_at" => _} =
             ctx.monitor |> Path.join("heartbeat.json") |> File.read!() |> Jason.decode!()
  end
end
