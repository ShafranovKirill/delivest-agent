defmodule DelivestAgent.ComposePsTest do
  use ExUnit.Case, async: true

  alias DelivestAgent.{Compose, FakeRunner, Project}

  @project %Project{
    name: "test",
    dir: "/tmp/test",
    files: ["compose.yml"],
    agent_service: "agent"
  }
  @warning ~s(time="2026-11-06T10:00:00Z" level=warning msg="The DB_PASSWORD variable is not set")
  @container %{"ID" => "abc", "Service" => "postgres", "State" => "running"}

  test "parses a JSON array surrounded by Compose warnings" do
    output = @warning <> "\n" <> Jason.encode!([@container]) <> "\nWARN[0000] ignored\n"
    stub(output)
    assert {:ok, [@container]} = Compose.ps(@project)
  end

  test "parses NDJSON surrounded by Compose warnings" do
    output =
      "WARNING: unset variable\n" <>
        Jason.encode!(@container) <>
        "\n" <>
        Jason.encode!(%{@container | "ID" => "def"}) <> "\n" <> @warning

    stub(output)
    assert {:ok, [@container, %{"ID" => "def"}]} = Compose.ps(@project)
  end

  test "empty or warning-only output has no containers" do
    stub(@warning <> "\n")
    assert {:ok, []} = Compose.ps(@project)
    stub("\n")
    assert {:ok, []} = Compose.ps(@project)
  end

  test "malformed JSON and non-warning text return structured errors" do
    for output <- [
          "[{bad}]",
          Jason.encode!(@container) <> "\n{bad}",
          "unexpected text\n" <> Jason.encode!(@container),
          "[1]"
        ] do
      stub(output)
      assert {:error, {1, message}} = Compose.ps(@project)
      assert message =~ "compose ps JSON"
    end
  end

  defp stub(output), do: FakeRunner.stub(fn "docker", _args -> {output, 0} end)
end
