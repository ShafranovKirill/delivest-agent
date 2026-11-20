defmodule DelivestAgent.CommandJournalTest do
  use ExUnit.Case, async: false
  alias DelivestAgent.CommandJournal

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:delivest_agent, :data_dir)
    Application.put_env(:delivest_agent, :data_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:delivest_agent, :data_dir, previous),
        else: Application.delete_env(:delivest_agent, :data_dir)
    end)

    :ok
  end

  test "repeated ID returns saved result and cannot execute a different command" do
    assert {:new, path} = CommandJournal.claim("command-1", "update", %{"version" => "1"})
    assert :ok = CommandJournal.finish(path, true, "ready")

    assert {:complete, %{"ok" => true, "output" => "ready"}} =
             CommandJournal.claim("command-1", "update", %{"version" => "1"})

    assert {:error, _} = CommandJournal.claim("command-1", "rollback", %{})
  end

  test "a process restart does not rerun an unfinished command" do
    assert {:new, _path} = CommandJournal.claim("command-2", "update", %{})
    assert {:interrupted, _} = CommandJournal.claim("command-2", "update", %{})
  end
end
