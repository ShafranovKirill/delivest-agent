defmodule DelivestAgent.Status do
  alias DelivestAgent.{Compose, Config, Metrics, Project, Runner}

  @checked_hosts ["api", "site"]

  def collect(project_result) do
    base = %{
      "agent_version" => Config.version(),
      "collected_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "checks" => checks(),
      "metrics" => Metrics.collect()
    }

    case project_result do
      {:ok, %Project{} = project} ->
        Map.merge(base, %{
          "project" => project.name,
          "project_dir" => project.dir,
          "containers" => containers(project),
          "disk" => disk(project.dir)
        })

      {:error, reason} ->
        Map.put(base, "error", inspect(reason))
    end
  end

  def containers(project) do
    case Compose.containers(project) do
      {:ok, containers} ->
        revisions = revisions(Enum.map(containers, & &1["ID"]))

        Enum.map(containers, fn container ->
          %{
            "service" => container["Service"],
            "state" => container["State"],
            "health" => blank(container["Health"]),
            "status" => container["Status"],
            "image" => container["Image"],
            "revision" => revisions[container["ID"]]
          }
        end)

      {:error, {_status, output}} ->
        [%{"error" => String.trim(output)}]
    end
  end

  def checks do
    gateway = Config.get(:gateway_url, "http://gateway")

    Config.hosts()
    |> Map.take(@checked_hosts)
    |> Map.new(fn {kind, host} -> {kind, check(gateway, host)} end)
  end

  def check(gateway, host) do
    started = System.monotonic_time(:millisecond)
    request = {String.to_charlist(gateway <> "/"), [{~c"host", String.to_charlist(host)}]}

    result =
      case :httpc.request(
             :get,
             request,
             [timeout: 5_000, connect_timeout: 3_000, autoredirect: false],
             body_format: :binary
           ) do
        {:ok, {{_version, status, _reason}, _headers, _body}} ->
          %{"ok" => status < 500, "status" => status}

        {:error, reason} ->
          %{"ok" => false, "error" => inspect(reason)}
      end

    Map.put(result, "ms", System.monotonic_time(:millisecond) - started)
  end

  def disk(dir) do
    with {output, 0} <- Runner.cmd("df", ["-Pk", dir]),
         [_header, line | _] <- String.split(output, "\n", trim: true),
         [_fs, total, used, free | _] <- String.split(line) do
      %{
        "total_kb" => String.to_integer(total),
        "used_kb" => String.to_integer(used),
        "free_kb" => String.to_integer(free)
      }
    else
      _ -> nil
    end
  end

  defp revisions([]), do: %{}

  defp revisions(ids) do
    format = ~s({{.Id}} {{index .Config.Labels "org.opencontainers.image.revision"}})

    case Runner.cmd("docker", ["inspect", "--format", format | ids]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, " ", parts: 2) do
            [id, revision] -> Enum.map(ids, &{&1, id, blank(String.trim(revision))})
            _ -> []
          end
        end)
        |> Enum.filter(fn {short, full, _revision} -> String.starts_with?(full, short) end)
        |> Map.new(fn {short, _full, revision} -> {short, revision} end)

      _ ->
        %{}
    end
  end

  defp blank(value) when value in [nil, "", "<no value>"], do: nil
  defp blank(value), do: value
end
