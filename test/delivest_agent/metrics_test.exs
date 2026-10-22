defmodule DelivestAgent.MetricsTest do
  use ExUnit.Case, async: true

  alias DelivestAgent.Metrics

  @stat """
  cpu  100 0 50 800 50 0 0 0 0 0
  cpu0 50 0 25 400 25 0 0 0 0 0
  cpu1 50 0 25 400 25 0 0 0 0 0
  intr 12345
  """

  test "reads the cpu counters of every core" do
    assert %{total: 1000, idle: 850, count: 2} = Metrics.parse_cpu(@stat)
    assert Metrics.parse_cpu("garbage") == nil
  end

  test "cpu percent is the busy share between two readings" do
    previous = %{total: 1000, idle: 850, count: 2}
    current = %{total: 2000, idle: 1100, count: 2}

    assert Metrics.cpu_percent(previous, current) == 75.0
    assert Metrics.cpu_percent(nil, current) == nil
    assert Metrics.cpu_percent(current, current) == nil
  end

  test "memory in use is what programs hold, without the file cache" do
    meminfo = """
    MemTotal:        8000000 kB
    MemFree:          500000 kB
    MemAvailable:    6000000 kB
    Cached:          5000000 kB
    """

    assert Metrics.parse_memory(meminfo) == %{
             "total_kb" => 8_000_000,
             "available_kb" => 6_000_000
           }

    assert Metrics.parse_memory("MemTotal: 1 kB") == nil
  end

  test "load average for 1, 5 and 15 minutes" do
    assert Metrics.parse_load("0.52 1.10 2.00 2/2851 1226214\n") == [0.52, 1.1, 2.0]
    assert Metrics.parse_load("") == nil
  end
end
