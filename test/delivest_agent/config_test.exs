defmodule DelivestAgent.ConfigTest do
  use ExUnit.Case, async: false

  alias DelivestAgent.{Config, Status}

  setup do
    previous = Application.fetch_env(:delivest_agent, :hosts)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore({:ok, value}), do: Application.put_env(:delivest_agent, :hosts, value)
  defp restore(:error), do: Application.delete_env(:delivest_agent, :hosts)

  test "reports a missing required host as a configuration error" do
    Application.put_env(:delivest_agent, :hosts, %{"api" => "api.example.com"})

    assert Config.required_hosts() == ["api", "site"]
    assert Config.missing_hosts() == ["site"]
    assert Config.config_errors() == ["site host is not configured"]

    checks = Status.checks()
    assert %{"ok" => false, "error" => "site host is not configured"} = checks["site"]
    assert Map.has_key?(checks, "api")
  end

  test "a complete configuration has no errors" do
    Application.put_env(:delivest_agent, :hosts, %{
      "api" => "api.example.com",
      "site" => "site.example.com",
      "s3" => nil
    })

    assert Config.missing_hosts() == []
    assert Config.config_errors() == []
    assert Config.host("s3") == nil
  end
end
