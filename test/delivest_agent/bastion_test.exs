defmodule DelivestAgent.BastionTest do
  use Slipstream.SocketTest

  alias DelivestAgent.{Bastion, ComposeStub, FakeRunner}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    FakeRunner.stub_global(ComposeStub.runner(self(), dir))
    Application.put_env(:delivest_agent, :data_dir, dir)
    Application.put_env(:delivest_agent, :bastion_test_mode, true)
    Application.put_env(:delivest_agent, :hosts, %{"api" => "api.example.com"})
    Application.put_env(:delivest_agent, :gateway_url, "http://127.0.0.1:1")

    on_exit(fn ->
      for key <- [:data_dir, :bastion_test_mode, :hosts, :gateway_url, FakeRunner],
          do: Application.delete_env(:delivest_agent, key)
    end)

    start_supervised!({Bastion, %{url: "wss://bastion.example.com", token: "secret"}})
    instance_id = File.read!(Path.join(dir, "instance_id"))
    %{topic: "instance:" <> instance_id}
  end

  test "builds the socket url with the token and instance id" do
    assert Bastion.socket_uri("wss://b.example.com/", "t", "id") ==
             "wss://b.example.com/agent/websocket?instance_id=id&token=t"
  end

  test "joins with instance info and sends heartbeats", %{topic: topic} do
    accept_connect(Bastion)

    assert_join(
      ^topic,
      %{"name" => "api.example.com", "hosts" => %{"api" => "api.example.com"}},
      :ok
    )

    assert_push(^topic, "heartbeat", %{
      "containers" => [%{"service" => "server"}],
      "running" => nil
    })
  end

  test "runs a command and reports the result", %{topic: topic} do
    accept_connect(Bastion)
    assert_join ^topic, _, :ok
    assert_push ^topic, "heartbeat", _

    push(Bastion, topic, "command", %{"id" => "c1", "action" => "restart"})

    assert_push ^topic, "command_started", %{"id" => "c1"}
    assert_push ^topic, "command_result", %{"id" => "c1", "ok" => true}
    {:messages, messages} = Process.info(self(), :messages)
    restarts = for {:cmd, "docker", ["compose" | args]} <- messages, "restart" in args, do: args
    assert restarts != []
  end

  test "rejects unknown actions", %{topic: topic} do
    accept_connect(Bastion)
    assert_join ^topic, _, :ok
    assert_push ^topic, "heartbeat", _

    push(Bastion, topic, "command", %{"id" => "c2", "action" => "rm -rf /"})

    assert_push(^topic, "command_result", %{
      "id" => "c2",
      "ok" => false,
      "output" => "unknown action: rm -rf /"
    })
  end
end
