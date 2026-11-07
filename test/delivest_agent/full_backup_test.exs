defmodule DelivestAgent.FullBackupTest do
  use ExUnit.Case, async: true

  alias DelivestAgent.{FakeRunner, FullBackup, OperationLock, Project}
  alias DelivestAgent.FullBackup.Archive
  alias DelivestAgent.FullBackup.Storage

  setup do
    dir = Path.join(System.tmp_dir!(), "full-backup-test-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    Process.put(:full_backup_test_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, project: %Project{name: "test", dir: dir, files: [], agent_service: "agent"}}
  end

  test "GNU tar roundtrip preserves hidden files and validates nested storage", %{dir: dir} do
    File.write!(Path.join(dir, "manifest.json"), "{}")
    File.write!(Path.join(dir, "database.dump"), "PGDMP")
    File.mkdir!(Path.join(dir, "data"))
    File.write!(Path.join(dir, "data/.hidden"), "private")
    storage = Path.join(dir, "storage.tar")
    assert {_, 0} = System.cmd("tar", ["--format=gnu", "-C", dir, "-cf", storage, "data"])
    assert :ok = Archive.validate(storage, :storage)
    output = Path.join(dir, "full.tar")
    assert :ok = Archive.create(dir, output)
    assert :ok = Archive.validate(output, :outer)
    extract = Path.join(dir, "extracted")
    File.mkdir!(extract)
    assert :ok = Archive.extract(output, extract)
    assert File.read!(Path.join(extract, "database.dump")) == "PGDMP"
    assert :ok = Archive.validate(Path.join(extract, "storage.tar"), :storage)
  end

  test "outer archive rejects traversal and symlinks", %{dir: dir} do
    File.write!(Path.join(dir, "manifest.json"), "{}")
    File.write!(Path.join(dir, "database.dump"), "PGDMP")
    File.write!(Path.join(dir, "storage.tar"), "x")
    traversal = Path.join(dir, "traversal.tar")

    assert {_, 0} =
             System.cmd("tar", [
               "--format=gnu",
               "--transform=s,^,../,",
               "-C",
               dir,
               "-cf",
               traversal,
               "manifest.json",
               "database.dump",
               "storage.tar"
             ])

    assert {:error, _} = Archive.validate(traversal, :outer)

    File.ln_s!("database.dump", Path.join(dir, "link"))
    symlink = Path.join(dir, "symlink.tar")
    assert {_, 0} = System.cmd("tar", ["--format=gnu", "-C", dir, "-cf", symlink, "link"])
    assert {:error, _} = Archive.validate(symlink, :storage)
  end

  test "truncated and appended archives are rejected", %{dir: dir} do
    File.write!(Path.join(dir, "manifest.json"), "{}")
    File.write!(Path.join(dir, "database.dump"), "PGDMP")
    File.write!(Path.join(dir, "storage.tar"), "x")
    output = Path.join(dir, "full.tar")
    assert :ok = Archive.create(dir, output)
    bytes = File.read!(output)
    File.write!(output, binary_part(bytes, 0, byte_size(bytes) - 9000))
    assert {:error, _} = Archive.validate(output, :outer)
    File.write!(output, bytes <> "evil")
    assert {:error, _} = Archive.validate(output, :outer)
  end

  test "operation lock is reentrant and reports busy without deleting another lock", %{
    dir: dir,
    project: project
  } do
    assert :ok =
             OperationLock.with_lock(project, fn ->
               OperationLock.with_lock(project, fn -> :ok end)
             end)

    lock = Path.join(dir, ".delivest-operation.lock")
    File.rm!(lock)
    File.mkdir!(lock)
    assert {:error, {1, message}} = OperationLock.with_lock(project, fn -> flunk("entered") end)
    assert message =~ "busy"
    assert File.dir?(lock)
  end

  test "operation lock releases after owner crash and rejects concurrent acquisition", %{
    project: project
  } do
    parent = self()

    owner =
      spawn(fn ->
        OperationLock.with_lock(project, fn ->
          send(parent, :lock_held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :lock_held, 2_000

    assert {_, 1} =
             System.cmd("flock", [
               "-n",
               Path.join(project.dir, ".delivest-operation.lock"),
               "true"
             ])

    attempts =
      for _ <- 1..8 do
        Task.async(fn -> OperationLock.with_lock(project, fn -> :entered end) end)
      end

    assert Enum.all?(attempts, fn task ->
             match?({:error, {1, _}}, Task.await(task, 2_000))
           end)

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

    assert eventually(fn -> OperationLock.with_lock(project, fn -> :recovered end) end) ==
             :recovered
  end

  test "operation lock releases after owning BEAM is killed", %{project: project} do
    script =
      "[dir] = System.argv(); DelivestAgent.OperationLock.with_lock(%{dir: dir}, fn -> IO.puts(\"LOCKED\"); Process.sleep(:infinity) end)"

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        args: [
          "-r",
          Path.expand("lib/delivest_agent/operation_lock.ex"),
          "-e",
          script,
          project.dir
        ]
      ])

    assert_port_output(port, "LOCKED", 5_000)
    assert {:error, {1, _}} = OperationLock.with_lock(project, fn -> :entered end)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    assert_receive {^port, {:exit_status, _}}, 5_000

    assert eventually(fn -> OperationLock.with_lock(project, fn -> :recovered end) end) ==
             :recovered
  end

  defp assert_port_output(port, expected, timeout, output \\ "") do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        unless String.contains?(output, expected),
          do: assert_port_output(port, expected, timeout, output)

      {^port, {:exit_status, status}} ->
        flunk("lock subprocess exited with #{status}: #{output}")
    after
      timeout -> flunk("lock subprocess did not print #{expected}: #{output}")
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    case fun.() do
      {:error, _} ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  test "full import requires explicit replace before reading Docker", %{
    dir: dir,
    project: project
  } do
    assert {:error, {1, message}} = FullBackup.import(project, Path.join(dir, "missing.tar"))
    assert message =~ "--replace"
  end

  test "CLI rejects invalid operation and missing replace", %{dir: dir} do
    assert_raise Mix.Error, ~r/usage:/, fn ->
      Mix.Tasks.Delivest.FullBackup.run(["unknown", "archive", "--project-dir", dir])
    end

    assert_raise Mix.Error, ~r/--replace/, fn ->
      Mix.Tasks.Delivest.FullBackup.run(["import", "archive", "--project-dir", dir])
    end
  end

  test "export dumps every table and restores only previously running services", %{
    dir: dir,
    project: project
  } do
    fake_docker(self())
    archive = Path.join(dir, "full.tar")
    assert {:ok, _} = FullBackup.export(project, archive)
    assert :ok = Archive.validate(archive, :outer)
    calls = collect_calls([])

    assert Enum.any?(calls, fn args ->
             Enum.member?(args, "pg_dump -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -Fc -f \"$1\"")
           end)

    refute Enum.any?(calls, fn args -> Enum.any?(args, &String.contains?(&1, "--exclude")) end)
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["stop", "gateway"]))
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["stop", "server"]))
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["stop", "s3"]))
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["start", "s3"]))
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["start", "server"]))
    refute Enum.any?(calls, &(Enum.take(&1, -2) == ["start", "client"]))
  end

  test "export error after stopping services restores previous state", %{
    dir: dir,
    project: project
  } do
    fake_docker(self(), fail_dump: true)
    assert {:error, _} = FullBackup.export(project, Path.join(dir, "full.tar"))
    calls = collect_calls([])
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["start", "s3"]))
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["start", "server"]))
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["start", "gateway"]))
  end

  test "successful migration export can leave source stopped", %{dir: dir, project: project} do
    fake_docker(self())
    assert {:ok, _} = FullBackup.export(project, Path.join(dir, "full.tar"), leave_stopped: true)
    calls = collect_calls([])
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["stop", "server"]))
    refute Enum.any?(calls, &(Enum.take(&1, -2) == ["start", "server"]))
  end

  test "corrupt archive fails before Docker mutation", %{dir: dir, project: project} do
    fake_docker(self())
    archive = Path.join(dir, "bad.tar")
    File.write!(archive, "bad")
    assert {:error, _} = FullBackup.import(project, archive, replace: true)
    assert collect_calls([]) == []
  end

  test "tampered digest fails before Docker mutation", %{dir: dir, project: project} do
    fake_docker(self())

    assert {:error, {1, message}} =
             FullBackup.import(project, make_archive(dir, tamper: true), replace: true)

    assert message =~ "SHA256 mismatch"
    assert collect_calls([]) == []
  end

  test "restore staging removes only stale Raft membership and preserves mirror and data", %{
    dir: dir
  } do
    data = Path.join(dir, "data")
    master = Path.join(data, "m9333")
    File.mkdir_p!(master)
    mirror = ~s({"maxVolumeId":8,"topologyId":"old-topology","growthFrozen":false})
    File.write!(Path.join(master, "max_volume_id"), mirror)

    for name <- ~w(log conf snapshot state) do
      File.mkdir!(Path.join(master, name))
      File.write!(Path.join([master, name, "old-ip"]), "127.0.0.1")
    end

    File.write!(Path.join(data, ".hidden"), "hidden")
    File.mkdir!(Path.join(data, "filer"))
    File.write!(Path.join(data, "filer/meta"), "metadata")
    File.write!(Path.join(data, "1.dat"), "volume")

    assert :ok = Storage.prepare(dir)
    assert File.read!(Path.join(master, "max_volume_id")) == mirror
    assert File.read!(Path.join(data, ".hidden")) == "hidden"
    assert File.read!(Path.join(data, "filer/meta")) == "metadata"
    assert File.read!(Path.join(data, "1.dat")) == "volume"

    for name <- ~w(log conf snapshot state) do
      refute File.exists?(Path.join(master, name))
    end
  end

  test "incomplete master mirror aborts import before service stop", %{dir: dir, project: project} do
    fake_docker(self())
    archive = make_archive(dir, mirror: ~s({"maxVolumeId":8}))
    assert {:error, {1, message}} = FullBackup.import(project, archive, replace: true)
    assert message =~ "master mirror"
    refute Enum.any?(collect_calls([]), &Enum.member?(&1, "stop"))
  end

  test "missing master mirror with volume data aborts before service stop", %{
    dir: dir,
    project: project
  } do
    fake_docker(self())
    archive = make_archive(dir, mirror: :missing)
    assert {:error, {1, message}} = FullBackup.import(project, archive, replace: true)
    assert message =~ "master mirror"
    refute Enum.any?(collect_calls([]), &Enum.member?(&1, "stop"))
  end

  test "pg_restore failure does not stop application", %{dir: dir, project: project} do
    fake_docker(self(), fail_restore: true)
    assert {:error, _} = FullBackup.import(project, make_archive(dir), replace: true)
    refute Enum.any?(collect_calls([]), &Enum.member?(&1, "stop"))
  end

  test "storage install failure restores cold copy and restarts app", %{
    dir: dir,
    project: project
  } do
    fake_docker(self(), fail_storage: true)
    assert {:error, {1, _}} = FullBackup.import(project, make_archive(dir), replace: true)
    calls = collect_calls([])
    assert Enum.count(calls, &storage_install_call?/1) == 2
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["start", "server"]))
  end

  test "storage rollback failure leaves application stopped", %{dir: dir, project: project} do
    fake_docker(self(), fail_storage: true, fail_rollback: true)
    assert {:error, {2, message}} = FullBackup.import(project, make_archive(dir), replace: true)
    assert message =~ "ROLLBACK FAILED"
    refute Enum.any?(collect_calls([]), &(Enum.take(&1, -2) == ["start", "server"]))
  end

  test "ambiguous DB swap leaves installed storage and app stopped", %{dir: dir, project: project} do
    fake_docker(self(), fail_swap: true, swap_state: "uncertain")
    assert {:error, {2, message}} = FullBackup.import(project, make_archive(dir), replace: true)
    assert message =~ "uncertain"
    calls = collect_calls([])
    assert Enum.count(calls, &storage_install_call?/1) == 1
    refute Enum.any?(calls, &(Enum.take(&1, -2) == ["start", "server"]))
  end

  test "failed DB transaction restores storage and resumes app", %{dir: dir, project: project} do
    fake_docker(self(), fail_swap: true, swap_state: "uncommitted")
    archive = make_archive(dir)
    assert {:ok, original} = Archive.digest(archive)
    assert {:error, {1, _}} = FullBackup.import(project, archive, replace: true)
    assert {:ok, ^original} = Archive.digest(archive)
    calls = collect_calls([])
    assert Enum.count(calls, &storage_install_call?/1) == 2
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["start", "server"]))
  end

  test "DB swap committed despite command error keeps new storage", %{dir: dir, project: project} do
    fake_docker(self(), fail_swap: true, swap_state: "committed")
    assert {:ok, message} = FullBackup.import(project, make_archive(dir), replace: true)
    assert message =~ "disconnected after commit"
    calls = collect_calls([])
    assert Enum.count(calls, &storage_install_call?/1) == 1
    assert Enum.any?(calls, &(Enum.take(&1, -2) == ["start", "server"]))
  end

  defp storage_install_call?(["cp", from, to]),
    do: String.ends_with?(from, "/.") and String.ends_with?(to, ":/data/")

  defp storage_install_call?(_), do: false

  defp make_archive(dir, opts \\ []) do
    source = Path.join(dir, "source")
    File.mkdir!(source)
    File.mkdir!(Path.join(source, "data"))
    File.write!(Path.join(source, "data/.hidden"), "hidden")
    master = Path.join(source, "data/m9333")
    File.mkdir!(master)

    if opts[:mirror] != :missing do
      File.write!(
        Path.join(master, "max_volume_id"),
        opts[:mirror] || ~s({"maxVolumeId":8,"topologyId":"source-topology","growthFrozen":false})
      )
    end

    for name <- ~w(log conf snapshot state) do
      File.mkdir!(Path.join(master, name))
      File.write!(Path.join([master, name, "old-ip"]), "127.0.0.1")
    end

    File.write!(Path.join(source, "data/1.dat"), "volume")
    File.write!(Path.join(source, "database.dump"), "PGDMP")
    storage = Path.join(source, "storage.tar")
    assert {_, 0} = System.cmd("tar", ["--format=gnu", "-C", source, "-cf", storage, "data"])
    {:ok, db} = Archive.digest(Path.join(source, "database.dump"))
    {:ok, storage_digest} = Archive.digest(storage)
    db = if opts[:tamper], do: %{db | sha256: String.duplicate("0", 64)}, else: db

    manifest = %{
      format: "delivest-full",
      version: 1,
      postgres_major: 16,
      seaweed_image_id: "sha256:weed",
      seaweed_image: "seaweed:4",
      bucket: "delivest",
      private_bucket: "delivest-private",
      schema_migrations: ["20240101000000"],
      files: %{database_dump: db, storage_tar: storage_digest}
    }

    File.write!(Path.join(source, "manifest.json"), Jason.encode!(manifest))
    archive = Path.join(dir, "import.tar")
    assert :ok = Archive.create(source, archive)
    archive
  end

  defp fake_docker(pid, opts \\ []) do
    FakeRunner.stub(fn command, args ->
      send(pid, {:docker_call, command, args})

      cond do
        command == "docker" and Enum.take(args, 1) == ["inspect"] ->
          id = List.last(args)

          info =
            case id do
              "s3-id" ->
                %{
                  "Image" => "sha256:weed",
                  "Mounts" => [%{"Destination" => "/data"}],
                  "Config" => %{
                    "Image" => "seaweed:4",
                    "Labels" => %{
                      "com.docker.compose.project" => "test",
                      "com.docker.compose.project.working_dir" =>
                        Process.get(:full_backup_test_dir)
                    },
                    "Entrypoint" => ["sh", "-c", "weed server -s3 -dir=/data"],
                    "Cmd" => [],
                    "Env" => ["S3_BUCKET=delivest"]
                  }
                }

              _ ->
                %{
                  "Image" => "sha256:pg",
                  "Config" => %{
                    "Image" => "postgres:16",
                    "Env" => [],
                    "Labels" => %{
                      "com.docker.compose.project" => "test",
                      "com.docker.compose.project.working_dir" =>
                        Process.get(:full_backup_test_dir)
                    }
                  }
                }
            end

          {Jason.encode!([info]), 0}

        command == "docker" and Enum.take(args, 1) == ["cp"] ->
          [_, from, to] = args

          cond do
            String.ends_with?(to, ":/data/") ->
              count = Process.get(:storage_cp_count, 0) + 1
              Process.put(:storage_cp_count, count)

              if opts[:fail_storage] == true and (count == 1 or opts[:fail_rollback] == true),
                do: {"storage copy failed", 1},
                else: {"", 0}

            String.starts_with?(from, "pg-id:") ->
              File.write!(to, "PGDMP")
              {"", 0}

            String.starts_with?(from, "s3-id:") ->
              File.mkdir_p!(to)
              File.write!(Path.join(to, ".hidden"), "private")
              File.mkdir_p!(Path.join(to, "m9333"))

              File.write!(
                Path.join(to, "m9333/max_volume_id"),
                ~s({"maxVolumeId":8,"topologyId":"source-topology","growthFrozen":false})
              )

              {"", 0}

            true ->
              {"", 0}
          end

        command == "docker" and "config" in args ->
          {Jason.encode!(%{
             "services" => %{
               "postgres" => %{"image" => "postgres:16"},
               "s3" => %{"image" => "seaweed:4"},
               "server" => %{"image" => "server:1"},
               "gateway" => %{"image" => "gateway:1"},
               "client" => %{"image" => "client:1"}
             }
           }), 0}

        command == "docker" and "ps" in args ->
          containers =
            for {service, state, id} <- [
                  {"postgres", "running", "pg-id"},
                  {"s3", "running", "s3-id"},
                  {"server", "running", "server-id"},
                  {"gateway", "running", "gateway-id"},
                  {"client", "exited", "client-id"}
                ],
                do: %{"Service" => service, "State" => state, "ID" => id}

          {Jason.encode!(containers), 0}

        command == "docker" and Enum.any?(args, &String.contains?(&1, "SHOW server_version_num")) ->
          {"160000\n", 0}

        command == "docker" and
            Enum.any?(args, &String.contains?(&1, "schema_migrations ORDER BY")) ->
          {"20240101000000\n", 0}

        command == "docker" and opts[:fail_dump] == true and
            Enum.any?(args, &String.contains?(&1, "pg_dump -U")) ->
          {"dump failed", 1}

        command == "docker" and opts[:fail_restore] == true and
            Enum.any?(args, &String.contains?(&1, "pg_restore -U")) ->
          {"restore failed", 1}

        command == "docker" and opts[:fail_swap] == true and
            Enum.any?(args, &String.contains?(&1, "ALTER DATABASE %I")) ->
          {"swap failed", 1}

        command == "docker" and opts[:fail_swap] == true and
            Enum.any?(args, &String.contains?(&1, "SELECT CASE")) ->
          {opts[:swap_state] <> "\n", 0}

        true ->
          {"", 0}
      end
    end)
  end

  defp collect_calls(calls) do
    receive do
      {:docker_call, "docker", args} -> collect_calls([args | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
