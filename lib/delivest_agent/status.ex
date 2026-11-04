defmodule DelivestAgent.Status do
  alias DelivestAgent.{Compose, Config, Database, Env, Metrics, Project, Release, Runner}

  @checked_hosts ["api", "site"]

  def collect(project_result) do
    base = %{
      "agent_version" => Config.version(),
      "collected_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "checks" => checks(),
      "config_errors" => Config.config_errors(),
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
              "image_id" => info[:image_id],
              "revision" => info[:revision],
              "version" => info[:version],
              "restarts" => info[:restarts]
            }
          end)

        {agent, containers} =
          Enum.split_with(described, &(&1["service"] == project.agent_service))

        agent =
          case agent do
            [agent | _] -> Map.take(agent, ["image", "revision", "version"])
            [] -> nil
          end

        {containers, agent}

      {:error, {_status, output}} ->
        {[%{"error" => String.trim(output)}], nil}
    end
  end

  # A required host that is not configured is a configuration error, not an
  # empty list of checks. The health check must see it and refuse to report a
  # successful update.
  def checks do
    gateway = Config.get(:gateway_url, "http://gateway")

    Map.new(@checked_hosts, fn kind ->
      case Config.host(kind) do
        nil ->
          {kind, %{"ok" => false, "error" => "#{kind} host is not configured"}}

        host ->
          {kind, check(gateway, host, kind(kind))}
      end
    end)
  end

  @doc """
  Checks one host. Without an explicit kind the site is checked, which keeps the
  old call sites working.
  """
  def check(gateway, host), do: check(gateway, host, :site)

  def check(gateway, host, kind) do
    started = System.monotonic_time(:millisecond)
    path = if kind == :api, do: "/ready", else: "/"
    # The internal gateway uses HTTP, behind the proxy that terminates public TLS.
    headers = [{~c"host", String.to_charlist(host)}, {~c"x-forwarded-proto", ~c"https"}]
    request = {String.to_charlist(gateway <> path), headers}

    result =
      case :httpc.request(
             :get,
             request,
             [timeout: 5_000, connect_timeout: 3_000, autoredirect: false],
             body_format: :binary
           ) do
        {:ok, {{_version, status, _reason}, _headers, body}} ->
          ok = status == 200 and body_ok?(kind, body)

          result =
            if ok,
              do: %{"ok" => true, "status" => status},
              else: %{"ok" => false, "status" => status}

          result =
            if not ok and status == 200,
              do: Map.put(result, "error", "not ready"),
              else: result

          Map.merge(result, details(kind, body))

        {:error, reason} ->
          %{"ok" => false, "error" => inspect(reason)}
      end

    Map.put(result, "ms", System.monotonic_time(:millisecond) - started)
  end

  defp kind("api"), do: :api
  defp kind(_kind), do: :site

  # The API is ready only when it says so: an HTML error page or a 404 from the
  # gateway is still an answer, but not a deployed application.
  defp body_ok?(:api, body) do
    case Jason.decode(body) do
      {:ok, %{"status" => "ok"}} -> true
      _ -> false
    end
  end

  defp body_ok?(:site, body), do: String.contains?(body, ~s(id="app"))

  defp details(:api, body) do
    case Jason.decode(body) do
      {:ok, %{"version" => version}} when is_binary(version) -> %{"version" => version}
      _ -> %{}
    end
  end

  defp details(_kind, _body), do: %{}

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
      ~s({{.Id}}|{{.RestartCount}}|{{index .Config.Labels "org.opencontainers.image.version"}}|{{index .Config.Labels "org.opencontainers.image.revision"}}|{{.Image}})

    case Runner.cmd("docker", ["inspect", "--format", format | ids]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, "|", parts: 5) do
            [id, restarts, version, revision, image_id] ->
              [{id, restarts, version, revision, image_id}]

            [id, restarts, version, revision] ->
              [{id, restarts, version, revision, ""}]

            [id, restarts, version] ->
              [{id, restarts, version, "", ""}]

            [id, restarts] ->
              [{id, restarts, "", "", ""}]

            _ ->
              []
          end
        end)
        |> Enum.flat_map(fn {full, restarts, version, revision, image_id} ->
          info = %{
            revision: blank(String.trim(revision)),
            version: blank(String.trim(version)),
            image_id: blank(String.trim(image_id)),
            restarts: integer(restarts)
          }

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
