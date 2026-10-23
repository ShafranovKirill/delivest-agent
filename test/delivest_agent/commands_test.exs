defmodule DelivestAgent.CommandsTest do
  use ExUnit.Case, async: false

  alias DelivestAgent.{Backup, Commands, ComposeStub, FakeRunner, Project, Release}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.rm(Release.state_path())
    FakeRunner.stub(ComposeStub.runner(self(), dir))
    %{project: Project.discover("agent-container"), dir: dir}
  end

  defp compose_calls do
    receive do
      {:cmd, "docker", ["compose" | args]} ->
        [args |> Enum.drop_while(&(&1 != "-f")) |> Enum.drop(2) | compose_calls()]

      {:cmd, _command, _args} ->
        compose_calls()
    after
      0 -> []
    end
  end

  test "discovers the compose project from its own container labels", %{
    project: project,
    dir: dir
  } do
    assert {:ok, %Project{name: "delivest", dir: ^dir, agent_service: "agent"} = found} = project
    assert found.files == [Path.join(dir, "docker-compose.yml")]

    assert ["compose", "-p", "delivest", "--project-directory", ^dir, "-f", _file, "ps"] =
             Project.compose_args(found, ["ps"])
  end

  test "refuses to work when the project dir is not mounted at the same path" do
    FakeRunner.stub(ComposeStub.runner(self(), "/not/mounted/here"))
    assert {:error, :project_dir_not_mounted} = Project.discover("agent-container")
  end

  test "update pulls and recreates every service except the agent itself", %{
    project: project,
    dir: dir
  } do
    File.mkdir!(Path.join(dir, ".git"))

    assert {:ok, output} = Commands.run("update", %{}, project)
    assert output =~ "== git pull\nAlready up to date."
    assert output =~ "== docker image prune"

    %{uid: uid} = File.stat!(dir)
    git = ["git", "-C", dir, "pull", "--ff-only"]

    if uid == 0,
      do: assert_received({:cmd, "git", ["-C", ^dir, "pull", "--ff-only"]}),
      else:
        assert_received(
          {:cmd, "setpriv",
           ["--reuid", _, "--regid", _, "--clear-groups", "env", "HOME=/tmp" | ^git]}
        )

    services = ["gateway", "server", "client", "postgres"]

    assert [
             ["config", "--services"],
             ["pull" | ^services],
             ["up", "--detach" | ^services],
             ["restart", "gateway"]
           ] = Enum.reject(compose_calls(), &match?(["ps" | _], &1))
  end

  test "update remembers the running images and waits for the site", %{project: project} do
    assert {:ok, output} = Commands.run("update", %{}, project)
    assert output =~ "== backup before update\nskipped: the bastion did not ask for it"
    assert output =~ "== remember running images\nremembered 2 images"
    assert output =~ "== wait until the site answers\nhealthy after"

    assert_received {:cmd, "docker",
                     ["tag", "sha256:111", "ghcr.io/x/delivest-server:delivest-previous"]}

    assert_received {:cmd, "docker", ["tag", "sha256:222", "postgres:delivest-previous"]}
    assert %{"at" => _, "git" => nil} = Release.rollback_info()
  end

  test "update backs up the database first and stops when the backup fails", %{dir: dir} do
    FakeRunner.stub(ComposeStub.runner(self(), dir, %{cp: &write_copy/2}))
    args = %{"upload_url" => "https://bastion/agent/backups/1", "token" => "secret"}

    assert {:ok, output} = Commands.run("update", args, Project.discover("agent-container"))
    assert output =~ "== backup before update\ndatabase dump is 5 bytes, uploaded to the bastion"
    refute File.exists?(Backup.dump_path())

    FakeRunner.stub(
      ComposeStub.runner(self(), dir, %{cp: &write_copy/2, curl: {"403 Forbidden", 22}})
    )

    assert {:error, output} = Commands.run("update", args, Project.discover("agent-container"))
    assert output =~ "== backup before update failed\n403 Forbidden"
    refute output =~ "docker compose pull"
  end

  test "update rolls back when the site does not come up", %{dir: dir} do
    restarting =
      Jason.encode!(%{"ID" => "aaa111", "Service" => "server", "State" => "restarting"})

    FakeRunner.stub(ComposeStub.runner(self(), dir, %{ps: {restarting, 0}}))

    assert {:error, output} = Commands.run("update", %{}, Project.discover("agent-container"))
    assert output =~ "== wait until the site answers failed\nnot healthy after 0 s:"
    assert output =~ "container server is restarting"
    assert output =~ "== automatic rollback\n== restore previous images"
    refute output =~ "docker image prune"

    assert_received {:cmd, "docker",
                     [
                       "tag",
                       "ghcr.io/x/delivest-server:delivest-previous",
                       "ghcr.io/x/delivest-server:latest"
                     ]}

    assert [
             _config,
             _pull,
             ["up", "--detach" | _],
             ["restart", "gateway"],
             ["up", "--detach" | _],
             ["restart", "gateway"]
           ] = Enum.reject(compose_calls(), &match?(["ps" | _], &1))
  end

  test "rollback needs a previous update and brings back its images", %{project: project} do
    assert {:error, output} = Commands.run("rollback", %{}, project)
    assert output =~ "nothing to roll back to"

    assert {:ok, _} = Commands.run("update", %{}, project)
    compose_calls()

    assert {:ok, output} = Commands.run("rollback", %{}, project)
    assert output =~ "== restore previous images"
    assert output =~ "== git reset\nskipped: no git revision was remembered"

    assert [["config", "--services"], ["up", "--detach" | _], ["restart", "gateway"]] =
             compose_calls()
  end

  test "agent_update pulls the agent image and recreates it from a helper", %{
    project: project,
    dir: dir
  } do
    assert {:ok, output} = Commands.run("agent_update", %{}, project)

    assert output =~
             "== recreate the agent\nthe agent restarts with ghcr.io/x/delivest-agent:latest"

    assert_received {:cmd, "docker",
                     ["run", "--detach", "--rm", "--name", "delivest_agent_updater" | run]}

    assert ["pull", "agent"] in compose_calls()

    assert "#{dir}:#{dir}" in run
    assert "PWD=#{dir}" in run
    assert ["up", "--detach", "--force-recreate", "--no-deps", "agent"] == Enum.take(run, -5)
  end

  test "status reports the env keys missing from the example", %{project: project, dir: dir} do
    assert {:ok, %{"env" => nil}} = Commands.run("status", %{}, project)

    File.write!(
      Path.join(dir, ".env.example"),
      "# comment\nPHX_HOST=\nNEW_KEY=x\nexport OTHER=1\n"
    )

    File.write!(Path.join(dir, ".env"), "PHX_HOST=a.example.com\n#NEW_KEY=commented\n")

    assert {:ok, %{"env" => %{"missing" => ["NEW_KEY", "OTHER"]}}} =
             Commands.run("status", %{}, project)
  end

  test "update skips git outside a checkout and stops when pull fails", %{dir: dir} do
    FakeRunner.stub(ComposeStub.runner(self(), dir, %{pull: {"denied", 1}}))

    assert {:error, output} =
             Commands.run("update", %{}, Project.discover("agent-container"))

    assert output =~ "skipped: not a git checkout"
    assert output =~ "== docker compose pull failed\ndenied"
    refute Enum.any?(compose_calls(), &match?(["up" | _], &1))
  end

  test "stop and start leave the agent running", %{project: project} do
    assert {:ok, _} = Commands.run("stop", %{}, project)
    assert {:ok, _} = Commands.run("start", %{}, project)

    assert [_, ["stop" | stopped], _, ["up", "--detach" | started]] = compose_calls()
    refute "agent" in stopped
    refute "agent" in started
  end

  test "logs accept only known services and clamp the tail", %{project: project} do
    assert {:ok, _} = Commands.run("logs", %{"service" => "server", "tail" => "99999"}, project)
    assert [_, ["logs", "--no-color", "--tail", "2000", "server"]] = compose_calls()

    assert {:error, "unknown service: agent"} =
             Commands.run("logs", %{"service" => "agent"}, project)
  end

  test "status reports containers without the agent with revisions and disk", %{project: project} do
    assert {:ok, status} = Commands.run("status", %{}, project)

    assert [%{"service" => "server", "revision" => "abc123", "health" => nil, "restarts" => 3}] =
             status["containers"]

    assert status["agent"] == %{
             "image" => "ghcr.io/x/delivest-agent:latest",
             "revision" => "agent42"
           }

    assert status["disk"] == %{"total_kb" => 1000, "used_kb" => 400, "free_kb" => 600}
    assert status["project"] == "delivest"
  end

  test "status reports crm problems with orders and errors and the database size", %{dir: dir} do
    order = %{"number" => "A001", "status" => "failed", "error" => "timeout"}
    orders = %{"last_hour" => 0, "usual" => 6.5}
    errors = %{"last_5m" => 2, "last_hour" => 10, "latest" => []}

    stats =
      Jason.encode!(%{
        "crm" => [order],
        "orders" => orders,
        "errors" => errors,
        "size_bytes" => 1024
      })

    FakeRunner.stub(ComposeStub.runner(self(), dir, %{exec: {stats <> "\n", 0}}))

    assert {:ok,
            %{
              "crm" => [^order],
              "orders" => ^orders,
              "errors" => ^errors,
              "database" => %{"size_bytes" => 1024}
            }} = Commands.run("status", %{}, Project.discover("agent-container"))

    FakeRunner.stub(ComposeStub.runner(self(), dir, %{exec: {"psql: error", 2}}))

    assert {:ok, %{"crm" => nil, "orders" => nil, "database" => nil}} =
             Commands.run("status", %{}, Project.discover("agent-container"))
  end

  test "env_read returns the .env of the project", %{project: project, dir: dir} do
    assert {:ok, ""} = Commands.run("env_read", %{}, project)

    File.write!(Path.join(dir, ".env"), "PHX_HOST=a.example.com\n")
    assert {:ok, "PHX_HOST=a.example.com\n"} = Commands.run("env_read", %{}, project)
  end

  test "env_write keeps a backup and the file mode and recreates the services", %{
    project: project,
    dir: dir
  } do
    path = Path.join(dir, ".env")
    File.write!(path, "OLD=1\n")
    File.chmod!(path, 0o640)

    assert {:ok, output} =
             Commands.run("env_write", %{"content" => "NEW=2\r\nOTHER=3"}, project)

    assert output =~ "== write .env\nsaved"
    assert File.read!(path) == "NEW=2\nOTHER=3\n"
    assert File.read!(path <> ".bak") == "OLD=1\n"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o640
    refute File.exists?(path <> ".tmp")

    services = ["gateway", "server", "client", "postgres"]

    assert [["config", "--services"], ["up", "--detach" | ^services], ["restart", "gateway"]] =
             compose_calls()
  end

  test "env_write without content changes nothing", %{project: project, dir: dir} do
    assert {:error, output} = Commands.run("env_write", %{}, project)
    assert output =~ "== write .env failed\ncontent is required"
    refute File.exists?(Path.join(dir, ".env"))
    refute Enum.any?(compose_calls(), &match?(["up" | _], &1))
  end

  defp write_copy(_command, args) do
    File.mkdir_p!(Backup.dir())
    File.write!(List.last(args), "PGDMP")
    {"", 0}
  end

  defp write_download(_command, args) do
    ["--output", path | _] = Enum.drop_while(args, &(&1 != "--output"))
    File.write!(path, "PGDMP")
    {"", 0}
  end

  test "backup dumps the database without logs and uploads it", %{dir: dir} do
    FakeRunner.stub(ComposeStub.runner(self(), dir, %{cp: &write_copy/2}))
    args = %{"upload_url" => "https://bastion/agent/backups/1", "token" => "secret"}

    assert {:ok, output} = Commands.run("backup", args, Project.discover("agent-container"))
    assert output =~ "== dump database\ndatabase dump is 5 bytes"
    assert output =~ "== upload to bastion"

    assert [
             ["config", "--services"],
             ["exec", "-T", "postgres", "sh", "-c", script, "sh", "/tmp/delivest-backup.dump"],
             ["cp", "postgres:/tmp/delivest-backup.dump", _],
             ["exec", "-T", "postgres", "rm", "-f", _]
           ] = compose_calls()

    assert script =~ "--exclude-table-data=app_logs"
    refute File.exists?(Backup.dump_path())
  end

  test "backup sends the token in a header and not in the url", %{dir: dir} do
    FakeRunner.stub(ComposeStub.runner(self(), dir, %{cp: &write_copy/2}))
    args = %{"upload_url" => "https://bastion/agent/backups/1", "token" => "secret"}

    Commands.run("backup", args, Project.discover("agent-container"))

    assert_received {:cmd, "curl", curl}
    assert "Authorization: Bearer secret" in curl
    assert List.last(curl) == "https://bastion/agent/backups/1"
  end

  test "failed upload fails the backup and removes the dump", %{dir: dir} do
    FakeRunner.stub(
      ComposeStub.runner(self(), dir, %{cp: &write_copy/2, curl: {"403 Forbidden", 22}})
    )

    args = %{"upload_url" => "https://bastion/agent/backups/1", "token" => "secret"}

    assert {:error, output} = Commands.run("backup", args, Project.discover("agent-container"))
    assert output =~ "== upload to bastion failed\n403 Forbidden"
    refute File.exists?(Backup.dump_path())
  end

  test "restore stops the server then restores and starts it again", %{dir: dir} do
    FakeRunner.stub(ComposeStub.runner(self(), dir, %{curl: &write_download/2}))
    args = %{"download_url" => "https://bastion/agent/backups/1/file", "token" => "secret"}

    assert {:ok, output} = Commands.run("restore", args, Project.discover("agent-container"))
    assert output =~ "== download backup\ndownloaded 5 bytes"
    assert output =~ "== start server"

    assert [
             ["config", "--services"],
             ["stop", "server"],
             ["cp", _, "postgres:/tmp/delivest-restore.dump"],
             ["exec", "-T", "postgres", "sh", "-c", script, "sh", "/tmp/delivest-restore.dump"],
             ["exec", "-T", "postgres", "rm", "-f", "/tmp/delivest-restore.dump"],
             ["up", "--detach", "server"]
           ] = compose_calls()

    assert script =~ "_before_restore"
    refute File.exists?(Backup.restore_path())
  end

  test "failed restore still starts the server", %{dir: dir} do
    FakeRunner.stub(
      ComposeStub.runner(self(), dir, %{
        curl: &write_download/2,
        exec: fn command, args ->
          send(self(), {:cmd, command, args})

          if "sh" in args,
            do: {"restore failed, the live database is untouched", 1},
            else: {"", 0}
        end
      })
    )

    args = %{"download_url" => "https://bastion/agent/backups/1/file", "token" => "secret"}

    assert {:error, output} = Commands.run("restore", args, Project.discover("agent-container"))
    assert output =~ "== restore database failed\nrestore failed, the live database is untouched"
    assert output =~ "== start server"
    assert ["up", "--detach", "server"] = List.last(compose_calls())
  end

  test "restore without a download url does not stop the server", %{project: project} do
    assert {:error, output} = Commands.run("restore", %{}, project)
    assert output =~ "download_url and token are required"
    refute Enum.any?(compose_calls(), &match?(["stop" | _], &1))
  end

  test "unknown actions and missing projects are errors" do
    assert {:error, "unknown action: rm"} = Commands.run("rm", %{}, {:error, :nope})

    assert {:error, "compose project is not available: :nope"} =
             Commands.run("stop", %{}, {:error, :nope})
  end
end
