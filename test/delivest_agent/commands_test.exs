defmodule DelivestAgent.CommandsTest do
  use ExUnit.Case, async: true

  alias DelivestAgent.{Commands, ComposeStub, FakeRunner, Project}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
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
           ] = compose_calls()
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

    assert [%{"service" => "server", "revision" => "abc123", "health" => nil}] =
             status["containers"]

    assert status["disk"] == %{"total_kb" => 1000, "used_kb" => 400, "free_kb" => 600}
    assert status["project"] == "delivest"
  end

  test "unknown actions and missing projects are errors" do
    assert {:error, "unknown action: rm"} = Commands.run("rm", %{}, {:error, :nope})

    assert {:error, "compose project is not available: :nope"} =
             Commands.run("stop", %{}, {:error, :nope})
  end
end
