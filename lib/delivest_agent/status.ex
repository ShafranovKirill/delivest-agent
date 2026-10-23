defmodule DelivestAgent.Status do
  alias DelivestAgent.{Compose, Config, Database, Env, Metrics, Project, Release, Runner}

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
        {containers, agent} = containers_and_agent(project)
        database = Database.stats(project)

        Map.merge(base, %{
          "project" => project.name,
          "project_dir" => project.dir,
          "containers" => containers,
          "agent" => agent,
          "disk" => disk(project.dir),
          "crm" => database["crm"],
          "orders" => database["orders"],
          "errors" => database["errors"],
          "database" => database["size_bytes"] && %{"size_bytes" => database["size_bytes"]},
          "env" => Env.check(project),
          "rollback" => Release.rollback_info()
        })

      {:error, reason} ->
        Map.put(base, "error", inspect(reason))
    end
  end

  def containers(project), do: project |> containers_and_agent() |> elem(0)

  defp containers_and_agent(project) do
    case Compose.ps(project) do
      {:ok, all} ->
        inspected = inspect_containers(Enum.map(all, & &1["ID"]))

        described =
          Enum.map(all, fn container ->
            info = inspected[container["ID"]] || %{}

            %{
              "service" => container["Service"],
              "state" => container["State"],
              "health" => blank(container["Health"]),
              "status" => container["Status"],
              "image" => container["Image"],
              "revision" => info[:revision],
              "restarts" => info[:restarts]
            }
          end)

        {agent, containers} =
          Enum.split_with(described, &(&1["service"] == project.agent_service))

        agent =
          case agent do
            [agent | _] -> Map.take(agent, ["image", "revision"])
            [] -> nil
          end

        {containers, agent}

      {:error, {_status, output}} ->
        {[%{"error" => String.trim(output)}], nil}
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

  defp inspect_containers([]), do: %{}

  defp inspect_containers(ids) do
    format =
      ~s({{.Id}} {{.RestartCount}} {{index .Config.Labels "org.opencontainers.image.revision"}})

    case Runner.cmd("docker", ["inspect", "--format", format | ids]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, " ", parts: 3) do
            [id, restarts, revision] -> [{id, restarts, revision}]
            [id, restarts] -> [{id, restarts, ""}]
            _ -> []
          end
        end)
        |> Enum.flat_map(fn {full, restarts, revision} ->
          info = %{revision: blank(String.trim(revision)), restarts: integer(restarts)}
          for short <- ids, String.starts_with?(full, short), do: {short, info}
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp blank(value) when value in [nil, "", "<no value>"], do: nil
  defp blank(value), do: value
end
