defmodule DelivestAgent.BackupJobsTest do
  use ExUnit.Case, async: false

  alias DelivestAgent.{BackupJobs, FakeRunner, Project}

  @id "11111111-1111-4111-8111-111111111111"
  @staff "22222222-2222-4222-8222-222222222222"

  defmodule Engine do
    def export(_project, path, opts) do
      send(
        Application.fetch_env!(:delivest_agent, :backup_jobs_test_pid),
        {:engine, :export, opts}
      )

      File.write!(path, "archive")
      Application.get_env(:delivest_agent, :backup_jobs_test_result, {:ok, "done"})
    end

    def import(_project, _path, opts) do
      send(
        Application.fetch_env!(:delivest_agent, :backup_jobs_test_pid),
        {:engine, :import, opts}
      )

      Application.get_env(:delivest_agent, :backup_jobs_test_result, {:ok, "done"})
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "backup-jobs-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([dir, "jobs", @id]))
    Application.put_env(:delivest_agent, :backup_jobs_test_pid, self())
    Application.delete_env(:delivest_agent, :backup_jobs_test_result)

    project = %Project{
      name: "test",
      dir: dir,
      files: [Path.join(dir, "compose.yml")],
      agent_service: "agent"
    }

    on_exit(fn ->
      Application.delete_env(:delivest_agent, :backup_jobs_test_pid)
      Application.delete_env(:delivest_agent, :backup_jobs_test_result)
      Application.delete_env(:delivest_agent, FakeRunner)
      File.rm_rf!(dir)
    end)

    %{dir: dir, project: project, job_dir: Path.join([dir, "jobs", @id])}
  end

  test "compose export claims once, writes archive/status/heartbeat and preserves owner", ctx do
    request(ctx, "export", "compose")
    stub_compose(true)
    {:ok, pid} = start(ctx)
    assert_receive {:engine, :export, opts}, 2_000
    assert opts[:app_stopped] == false
    assert status(ctx, "complete")["safe_to_resume"] == true
    assert File.read!(Path.join(ctx.job_dir, "archive.tar")) == "archive"
    assert File.stat!(Path.join(ctx.job_dir, "archive.tar")).uid == File.stat!(ctx.job_dir).uid
    assert %{"protocol" => 1} = read_json(Path.join(ctx.dir, "heartbeat.json"))
    Process.sleep(50)
    refute_receive {:engine, _, _}
    GenServer.stop(pid)
  end

  test "external job waits for matching quiesced marker", ctx do
    request(ctx, "export", "external")
    stub_compose(false)
    {:ok, pid} = start(ctx)
    assert status(ctx, "waiting")["safe_to_resume"] == false
    refute_receive {:engine, _, _}, 100
    File.write!(Path.join(ctx.job_dir, "quiesced.json"), Jason.encode!(%{id: @id}))
    assert_receive {:engine, :export, opts}, 2_000
    assert opts[:app_stopped] == true
    assert status(ctx, "complete")["safe_to_resume"] == true
    GenServer.stop(pid)
  end

  test "import passes replace and maps unsafe engine error to safe_to_resume false", ctx do
    request(ctx, "import", "compose")
    File.write!(Path.join(ctx.job_dir, "archive.tar"), "uploaded")

    Application.put_env(
      :delivest_agent,
      :backup_jobs_test_result,
      {:error, {2, "rollback failed"}}
    )

    stub_compose(true)
    {:ok, pid} = start(ctx)
    assert_receive {:engine, :import, opts}, 2_000
    assert opts[:replace] == true
    assert status(ctx, "failed")["safe_to_resume"] == false
    GenServer.stop(pid)
  end

  test "ordinary engine error is failed and safe to resume", ctx do
    request(ctx, "export", "compose")

    Application.put_env(
      :delivest_agent,
      :backup_jobs_test_result,
      {:error, {1, "invalid archive"}}
    )

    stub_compose(true)
    {:ok, pid} = start(ctx)
    assert_receive {:engine, :export, _}, 2_000
    assert status(ctx, "failed")["safe_to_resume"] == true
    GenServer.stop(pid)
  end

  test "restart marks claimed running job interrupted and never reruns", ctx do
    request(ctx, "import", "compose")
    File.mkdir!(Path.join(ctx.job_dir, "claimed"))
    File.write!(Path.join(ctx.job_dir, "status.json"), Jason.encode!(%{phase: "running"}))
    stub_compose(true)
    {:ok, pid} = start(ctx)
    assert status(ctx, "interrupted")["safe_to_resume"] == false
    refute_receive {:engine, _, _}, 100
    GenServer.stop(pid)
  end

  test "claimed job with missing or corrupt status requires review and never reruns", ctx do
    request(ctx, "import", "compose")
    File.mkdir!(Path.join(ctx.job_dir, "claimed"))
    stub_compose(true)
    {:ok, pid} = start(ctx)
    assert status(ctx, "interrupted")["safe_to_resume"] == false
    refute_receive {:engine, _, _}, 100
    GenServer.stop(pid)

    File.write!(Path.join(ctx.job_dir, "status.json"), "{invalid")
    {:ok, pid} = start(ctx)
    assert status(ctx, "interrupted")["safe_to_resume"] == false
    refute_receive {:engine, _, _}, 100
    GenServer.stop(pid)
  end

  test "claimed terminal status is preserved", ctx do
    request(ctx, "export", "compose")
    File.mkdir!(Path.join(ctx.job_dir, "claimed"))

    original = %{
      id: @id,
      action: "export",
      phase: "complete",
      safe_to_resume: true,
      message: "done"
    }

    File.write!(Path.join(ctx.job_dir, "status.json"), Jason.encode!(original))
    stub_compose(true)
    {:ok, pid} = start(ctx)
    Process.sleep(80)
    assert read_json(Path.join(ctx.job_dir, "status.json"))["message"] == "done"
    refute_receive {:engine, _, _}
    GenServer.stop(pid)
  end

  test "invalid ID and action never invoke engine", ctx do
    request(ctx, "delete", "compose")
    stub_compose(true)
    {:ok, pid} = start(ctx)
    refute_receive {:engine, _, _}, 100
    refute File.exists?(Path.join(ctx.job_dir, "claimed"))
    File.write!(Path.join(ctx.dir, "active.json"), Jason.encode!(%{protocol: 1, id: "../escape"}))
    refute_receive {:engine, _, _}, 100
    GenServer.stop(pid)
  end

  test "status persistence failure prevents engine execution", ctx do
    request(ctx, "export", "compose")
    File.mkdir!(Path.join(ctx.job_dir, "status.json"))
    stub_compose(true)
    {:ok, pid} = start(ctx)
    refute_receive {:engine, _, _}, 150
    refute File.exists?(Path.join(ctx.job_dir, "claimed"))
    GenServer.stop(pid)
  end

  test "external quiesce timeout fails safely without engine", ctx do
    request(ctx, "export", "external")
    stub_compose(false)
    {:ok, pid} = start(ctx, quiesce_timeout_ms: 80)
    assert status(ctx, "failed")["safe_to_resume"] == true
    refute_receive {:engine, _, _}
    GenServer.stop(pid)
  end

  defp start(ctx, opts \\ []),
    do:
      BackupJobs.start_link(
        Keyword.merge([dir: ctx.dir, project: ctx.project, engine: Engine, poll_ms: 20], opts)
      )

  defp request(ctx, action, mode) do
    File.write!(Path.join(ctx.dir, "active.json"), Jason.encode!(%{protocol: 1, id: @id}))

    File.write!(
      Path.join(ctx.job_dir, "request.json"),
      Jason.encode!(%{
        version: 1,
        id: @id,
        action: action,
        mode: mode,
        requested_by: @staff,
        created_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })
    )
  end

  defp stub_compose(server?) do
    services =
      if server?,
        do: %{"server" => %{}, "postgres" => %{}, "s3" => %{}},
        else: %{"postgres" => %{}, "s3" => %{}}

    FakeRunner.stub_global(fn _cmd, _args -> {Jason.encode!(%{"services" => services}), 0} end)
  end

  defp status(ctx, phase) do
    path = Path.join(ctx.job_dir, "status.json")

    Enum.reduce_while(1..100, nil, fn _, _ ->
      value =
        if File.regular?(path) do
          case File.read(path) do
            {:ok, bytes} ->
              case Jason.decode(bytes) do
                {:ok, json} -> json
                _ -> nil
              end

            _ ->
              nil
          end
        end

      if value && value["phase"] == phase,
        do: {:halt, value},
        else:
          (
            Process.sleep(20)
            {:cont, nil}
          )
    end) || flunk("status #{phase} was not written")
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()
end
