defmodule DelivestAgent.ComposeStub do
  def labels(dir) do
    Jason.encode!(%{
      "com.docker.compose.project" => "delivest",
      "com.docker.compose.project.working_dir" => dir,
      "com.docker.compose.project.config_files" => Path.join(dir, "docker-compose.yml"),
      "com.docker.compose.service" => "agent"
    })
  end

  def runner(test_pid, dir, overrides \\ %{}) do
    fn command, args ->
      send(test_pid, {:cmd, command, args})
      key = key(command, args)

      case Map.fetch(overrides, key) do
        {:ok, fun} when is_function(fun, 2) -> fun.(command, args)
        {:ok, response} -> response
        :error -> default(key, dir, args)
      end
    end
  end

  def key("docker", ["inspect", "--format", "{{json .Config.Labels}}" | _]), do: :labels

  def key("docker", ["inspect", "--format", "{{.Config.Image}} {{.Image}}" | _]),
    do: :images

  def key("docker", ["inspect", "--format", "{{.Id}}|{{.Config.Image}}|" <> _ | _]),
    do: :capture

  def key("docker", ["inspect" | _]), do: :revisions
  def key("docker", ["image", "inspect" | _]), do: :image_inspect
  def key("docker", ["tag" | _]), do: :tag
  def key("docker", ["run" | _]), do: :run
  def key("docker", ["rm" | _]), do: :rm
  def key("docker", ["image", "prune" | _]), do: :prune
  def key("curl", _args), do: :curl
  def key("git", ["-C", _dir, "rev-parse" | _]), do: :rev_parse
  def key("git", _args), do: :git

  def key("setpriv", args) do
    case Enum.drop_while(args, &(&1 != "git")) do
      ["git" | command] -> key("git", command)
      [] -> :git
    end
  end

  def key("df", _args), do: :df

  def key("docker", ["compose" | args]) do
    args =
      args
      |> Enum.drop_while(&(&1 != "-f"))
      |> Enum.drop(2)

    case args do
      ["config", "--format", "json"] -> :config_json
      [command | _] -> String.to_atom(command)
      [] -> :unknown
    end
  end

  # Lets a test override one command and fall back to the stub for the rest.
  def default_response(key, dir, args), do: default(key, dir, args)

  defp default(:labels, dir, _args), do: {labels(dir), 0}

  defp default(:config, _dir, _args), do: {"gateway\nserver\nclient\npostgres\nagent\n", 0}

  defp default(:config_json, _dir, _args) do
    gateway_digest = String.duplicate("a", 64)
    postgres_digest = String.duplicate("b", 64)
    s3_digest = String.duplicate("c", 64)

    services = %{
      "gateway" => %{"image" => "nginx:1.28-alpine@sha256:#{gateway_digest}"},
      "server" => %{"image" => "ghcr.io/x/delivest-server:latest"},
      "client" => %{"image" => "ghcr.io/x/delivest-client:latest"},
      "postgres" => %{"image" => "postgres:16-alpine@sha256:#{postgres_digest}"},
      "s3" => %{"image" => "chrislusf/seaweedfs:4.50@sha256:#{s3_digest}"},
      "agent" => %{"image" => "ghcr.io/x/delivest-agent:latest"}
    }

    {Jason.encode!(%{"services" => services}), 0}
  end

  defp default(:image_inspect, _dir, args) do
    ref = List.last(args)
    format = args |> Enum.drop_while(&(&1 != "--format")) |> Enum.at(1) || ""

    id =
      cond do
        String.starts_with?(ref, "ghcr.io/x/delivest-server") -> "sha256:111"
        String.starts_with?(ref, "ghcr.io/x/delivest-client") -> "sha256:444"
        String.starts_with?(ref, "nginx:") -> "sha256:333"
        String.starts_with?(ref, "postgres:") -> "sha256:222"
        String.starts_with?(ref, "chrislusf/seaweedfs") -> "sha256:555"
        true -> "sha256:111"
      end

    version =
      cond do
        String.starts_with?(ref, "ghcr.io/x/delivest-server") -> "1.1.0"
        String.starts_with?(ref, "ghcr.io/x/delivest-client") -> "2.0.0"
        true -> nil
      end

    output =
      if version && String.contains?(format, "version"), do: id <> "|" <> version, else: id

    {output <> "\n", 0}
  end

  defp default(:capture, _dir, _args) do
    lines = [
      "aaa111fullid|ghcr.io/x/delivest-server:latest|sha256:111|1.1.0",
      "ccc333fullid|ghcr.io/x/delivest-client:latest|sha256:444|2.0.0",
      "ddd444fullid|nginx:1.28-alpine@sha256:#{String.duplicate("a", 64)}|sha256:333|",
      "eee555fullid|postgres:16-alpine@sha256:#{String.duplicate("b", 64)}|sha256:222|",
      "fff666fullid|chrislusf/seaweedfs:4.50@sha256:#{String.duplicate("c", 64)}|sha256:555|"
    ]

    {Enum.join(lines, "\n") <> "\n", 0}
  end

  defp default(:ps, _dir, _args) do
    lines = [
      %{
        "ID" => "aaa111",
        "Service" => "server",
        "State" => "running",
        "Health" => "",
        "Status" => "Up 2 hours",
        "Image" => "ghcr.io/x/delivest-server:latest"
      },
      %{
        "ID" => "ccc333",
        "Service" => "client",
        "State" => "running",
        "Health" => "",
        "Status" => "Up 2 hours",
        "Image" => "ghcr.io/x/delivest-client:latest"
      },
      %{
        "ID" => "ddd444",
        "Service" => "gateway",
        "State" => "running",
        "Health" => "",
        "Status" => "Up 2 hours",
        "Image" => "nginx:1.28-alpine@sha256:#{String.duplicate("a", 64)}"
      },
      %{
        "ID" => "eee555",
        "Service" => "postgres",
        "State" => "running",
        "Health" => "",
        "Status" => "Up 2 hours",
        "Image" => "postgres:16-alpine@sha256:#{String.duplicate("b", 64)}"
      },
      %{
        "ID" => "fff666",
        "Service" => "s3",
        "State" => "running",
        "Health" => "",
        "Status" => "Up 2 hours",
        "Image" => "chrislusf/seaweedfs:4.50@sha256:#{String.duplicate("c", 64)}"
      },
      %{
        "ID" => "bbb222",
        "Service" => "agent",
        "State" => "running",
        "Health" => "",
        "Status" => "Up 2 hours",
        "Image" => "ghcr.io/x/delivest-agent:latest"
      }
    ]

    {Enum.map_join(lines, "\n", &Jason.encode!/1), 0}
  end

  defp default(:revisions, _dir, _args) do
    lines = [
      "aaa111fullid|3|1.1.0|abc123|sha256:111",
      "ccc333fullid|0|2.0.0|client42|sha256:444",
      "ddd444fullid|0|<no value>|gateway42|sha256:333",
      "eee555fullid|0|<no value>|postgres42|sha256:222",
      "fff666fullid|0|<no value>|s342|sha256:555",
      "bbb222fullid|0|<no value>|agent42|sha256:666"
    ]

    {Enum.join(lines, "\n") <> "\n", 0}
  end

  defp default(:images, _dir, _args),
    do: {"ghcr.io/x/delivest-server:latest sha256:111\npostgres:16-alpine sha256:222\n", 0}

  defp default(:rev_parse, _dir, _args), do: {"0123abc\n", 0}

  defp default(:df, _dir, _args),
    do:
      {"Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 1000 400 600 40% /\n",
       0}

  defp default(:git, _dir, _args), do: {"Already up to date.\n", 0}
  defp default(_key, _dir, _args), do: {"done\n", 0}
end
