defmodule DelivestAgent.StatusTest do
  use ExUnit.Case, async: true

  alias DelivestAgent.Status

  defp serve(status, body \\ "") do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test_pid = self()

    spawn_link(fn ->
      {:ok, conn} = :gen_tcp.accept(listen)
      {:ok, request} = :gen_tcp.recv(conn, 0, 2_000)
      send(test_pid, {:request, request})

      :gen_tcp.send(
        conn,
        "HTTP/1.1 #{status} X\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
          body
      )

      :gen_tcp.close(conn)
    end)

    "http://127.0.0.1:#{port}"
  end

  test "asks the API for readiness and keeps its version" do
    body = Jason.encode!(%{status: "ok", app: "delivest", version: "1.2.3"})

    assert %{"ok" => true, "status" => 200, "version" => "1.2.3", "ms" => ms} =
             Status.check(serve(200, body), "api.example.com", :api)

    assert is_integer(ms)
    assert_received {:request, request}
    assert request =~ ~r/^GET \/ready /i
    assert request =~ ~r/\r\nhost: api\.example\.com\r\n/i
    assert request =~ ~r/\r\nx-forwarded-proto: https\r\n/i
  end

  test "a 404 or an error page is not a ready API" do
    assert %{"ok" => false, "status" => 404} =
             Status.check(serve(404, "not found"), "api.example.com", :api)

    assert %{"ok" => false, "status" => 200, "error" => "not ready"} =
             Status.check(serve(200, "<html>maintenance</html>"), "api.example.com", :api)
  end

  test "checks the site marker, not just the status" do
    assert %{"ok" => true, "status" => 200} =
             Status.check(serve(200, ~s(<div id="app"></div>)), "site.example.com", :site)

    assert %{"ok" => false, "status" => 200, "error" => "not ready"} =
             Status.check(serve(200, "<html>maintenance</html>"), "site.example.com", :site)
  end

  test "server errors and refused connections fail the check" do
    assert %{"ok" => false, "status" => 502} = Status.check(serve(502), "site.example.com")
    assert %{"ok" => false, "error" => _} = Status.check("http://127.0.0.1:1", "site.example.com")
  end
end
