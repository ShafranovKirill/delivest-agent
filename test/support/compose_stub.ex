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
        :error -> default(key, dir)
      end
    end
  end

  def key("docker", ["inspect", "--format", "{{json .Config.Labels}}" | _]), do: :labels
  def key("docker", ["inspect", "--format", "{{.Config.Image}} {{.Image}}" | _]), do: :images
  def key("docker", ["inspect" | _]), do: :revisions
  def key("docker", ["tag" | _]), do: :tag
  def key("docker", ["run" | _]), do: :run
  def key("docker", ["rm" | _]), do: :rm
  def key("docker", ["image", "prune" | _]), do: :prune
  def key("curl", _args), do: :curl
  def key("git", ["-C", _dir, "rev-parse" | _]), do: :rev_parse
  def key("git", _args), do: :git
  def key("setpriv", _args), do: :git
  def key("df", _args), do: :df

  def key("docker", ["compose" | args]) do
    args |> Enum.drop_while(&(&1 != "-f")) |> Enum.drop(2) |> hd() |> String.to_atom()
  end

  defp default(:labels, dir), do: {labels(dir), 0}
  defp default(:config, _dir), do: {"gateway\nserver\nclient\npostgres\nagent\n", 0}

  defp default(:ps, _dir) do
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

  defp default(:revisions, _dir),
    do: {"aaa111fullid|3|1.1.0|abc123\nbbb222fullid|0|<no value>|agent42\n", 0}

  defp default(:images, _dir),
    do: {"ghcr.io/x/delivest-server:latest sha256:111\npostgres:16-alpine sha256:222\n", 0}

  defp default(:rev_parse, _dir), do: {"0123abc\n", 0}

  defp default(:df, _dir),
    do:
      {"Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 1000 400 600 40% /\n",
       0}

  defp default(:git, _dir), do: {"Already up to date.\n", 0}
  defp default(_key, _dir), do: {"done\n", 0}
end
