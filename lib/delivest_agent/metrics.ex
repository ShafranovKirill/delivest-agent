defmodule DelivestAgent.Metrics do
  alias DelivestAgent.Config

  @table __MODULE__

  def init, do: :ets.new(@table, [:named_table, :public, :set])

  def collect do
    cpu = read_cpu()

    %{
      "cpu_percent" => cpu && cpu_percent(previous_cpu(cpu), cpu),
      "cpus" => cpu && cpu.count,
      "load" => load(),
      "memory" => memory()
    }
  end

  def cpu_percent(nil, _current), do: nil

  def cpu_percent(previous, current) do
    total = current.total - previous.total
    idle = current.idle - previous.idle

    if total > 0, do: Float.round(100 * (total - idle) / total, 1), else: nil
  end

  def parse_cpu(stat) do
    lines = String.split(stat, "\n", trim: true)

    with ["cpu" | values] <- lines |> List.first("") |> String.split(),
         [user, nice, system, idle, iowait | rest] <- Enum.map(values, &String.to_integer/1) do
      %{
        total: user + nice + system + idle + iowait + Enum.sum(Enum.take(rest, 3)),
        idle: idle + iowait,
        count: Enum.count(lines, &Regex.match?(~r/^cpu\d+\s/, &1))
      }
    else
      _ -> nil
    end
  end

  def parse_memory(meminfo) do
    values =
      for line <- String.split(meminfo, "\n", trim: true),
          [key, value | _] <- [String.split(line)],
          into: %{},
          do: {String.trim_trailing(key, ":"), value}

    with {total, ""} <- Integer.parse(values["MemTotal"] || ""),
         {available, ""} <- Integer.parse(values["MemAvailable"] || "") do
      %{"total_kb" => total, "available_kb" => available}
    else
      _ -> nil
    end
  end

  def parse_load(loadavg) do
    case loadavg |> String.split() |> Enum.take(3) |> Enum.map(&Float.parse/1) do
      [{one, _}, {five, _}, {fifteen, _}] -> [one, five, fifteen]
      _ -> nil
    end
  end

  defp previous_cpu(current) do
    previous =
      case :ets.lookup(@table, :cpu) do
        [{:cpu, previous}] -> previous
        [] -> nil
      end

    :ets.insert(@table, {:cpu, current})
    previous
  rescue
    ArgumentError -> nil
  end

  defp read_cpu, do: read("stat", &parse_cpu/1)
  defp load, do: read("loadavg", &parse_load/1)
  defp memory, do: read("meminfo", &parse_memory/1)

  defp read(name, parse) do
    case File.read(Path.join(Config.get(:proc_dir, "/proc"), name)) do
      {:ok, content} -> parse.(content)
      {:error, _reason} -> nil
    end
  end
end
