defmodule DelivestAgent.StatusTest do
  use ExUnit.Case, async: true

  alias DelivestAgent.Status

  defp serve(status) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test_pid = self()

    spawn_link(fn ->
      {:ok, conn} = :gen_tcp.accept(listen)
      {:ok, request} = :gen_tcp.recv(conn, 0, 2_000)
      send(test_pid, {:request, request})

      :gen_tcp.send(
        conn,
        "HTTP/1.1 #{status} X\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
      )

      :gen_tcp.close(conn)
    end)

    "http://127.0.0.1:#{port}"
  end

  test "checks a site through the gateway with its own host header" do
    assert %{"ok" => true, "status" => 200, "ms" => ms} =
             Status.check(serve(200), "api.example.com")

    assert is_integer(ms)
    assert_received {:request, request}
    assert request =~ ~r/\r\nhost: api\.example\.com\r\n/i
  end

  test "server errors and refused connections fail the check" do
    assert %{"ok" => false, "status" => 502} = Status.check(serve(502), "site.example.com")
    assert %{"ok" => false, "error" => _} = Status.check("http://127.0.0.1:1", "site.example.com")
  end
end
