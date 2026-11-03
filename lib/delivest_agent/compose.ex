defmodule DelivestAgent.Compose do
  alias DelivestAgent.{Config, Project, Runner}

  @default_pull_retry_delays_ms [5_000, 15_000, 45_000]
  @digest ~r/@sha256:[0-9a-f]{64}\z/

  def services(%Project{} = project) do
    with {:ok, definitions} <- definitions(project) do
      {:ok, Enum.map(definitions, & &1.name)}
    end
  end

  # The image reference is the only thing that decides whether a pull can be skipped.
  # A digest always points at the same content, while a tag (including latest) may be
  # moved by the publisher. The application images deliberately use latest, so they are
  # always pulled as the target release.
  def definitions(%Project{} = project) do
    with {:ok, output} <- run(project, ["config", "--format", "json"]) do
      decode_definitions(project, output)
    end
  end

  def prepare_image(%Project{} = project, %{name: name, image: image}) do
    cond do
      not is_binary(image) or image == "" ->
        {:skip, "the service has no image reference"}

      pinned?(image) and image_present?(image) ->
        {:skip, "pinned image #{image} is already present"}

      true ->
        pull_with_retry(project, name, image)
    end
  end

  def pinned?(image) when is_binary(image), do: Regex.match?(@digest, image)
  def pinned?(_image), do: false

  def containers(%Project{} = project) do
    with {:ok, containers} <- ps(project) do
      {:ok, Enum.reject(containers, &(&1["Service"] == project.agent_service))}
    end
  end

  def ps(%Project{} = project) do
    with {:ok, output} <- run(project, ["ps", "--all", "--format", "json"]) do
      {:ok, decode_lines(output)}
    end
  end

  def pull(project, services), do: run(project, ["pull" | services])

  # The update path prepares every image first. Starting with `--pull never` then
  # guarantees that Compose cannot quietly fetch a mutable `latest` during `up` and
  # report a stale local image as a successful update.
  def up(project, services), do: run(project, ["up", "--detach" | services])

  def up_prepared(project, services),
    do: run(project, ["up", "--detach", "--pull", "never" | services])

  def stop(project, services), do: run(project, ["stop" | services])
  def restart(project, services), do: run(project, ["restart" | services])

  def logs(project, services, tail),
    do: run(project, ["logs", "--no-color", "--tail", to_string(tail) | services])

  def run(project, args) do
    case Runner.cmd("docker", Project.compose_args(project, args)) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  end

  defp decode_definitions(project, output) do
    case output |> json_body() |> Jason.decode() do
      {:ok, %{"services" => services}} when is_map(services) ->
        definitions =
          services
          |> Enum.map(fn {name, spec} -> %{name: name, image: spec["image"]} end)
          |> Enum.reject(&(&1.name == project.agent_service))
          |> Enum.sort_by(& &1.name)

        {:ok, definitions}

      {:ok, _config} ->
        {:error, {1, "docker compose config has no services"}}

      {:error, reason} ->
        {:error, {1, "cannot read docker compose config: #{Exception.message(reason)}"}}
    end
  end

  # Compose writes interpolation warnings next to the JSON on some installations. They are
  # not part of the document, so start reading at the first line that opens the object.
  defp json_body(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(fn line -> not String.starts_with?(String.trim_leading(line), "{") end)
    |> Enum.join("\n")
  end

  defp image_present?(image) do
    case Runner.cmd("docker", ["image", "inspect", "--format", "{{.Id}}", image]) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp pull_with_retry(project, name, image) do
    delays = Config.get(:pull_retry_delays_ms, @default_pull_retry_delays_ms)
    attempts = length(delays) + 1

    pull_attempt(project, name, image, delays, 1, attempts, "")
  end

  defp pull_attempt(project, name, image, delays, attempt, attempts, log) do
    case pull(project, [name]) do
      {:ok, output} ->
        {:ok, log <> "pulled #{image} on attempt #{attempt}/#{attempts}" <> output_note(output)}

      {:error, {status, output}} ->
        failed = log <> "attempt #{attempt}/#{attempts} failed: #{String.trim(output)}\n"

        case {rate_limited?(output), delays} do
          {true, [delay | rest]} ->
            Process.sleep(delay)

            pull_attempt(
              project,
              name,
              image,
              rest,
              attempt + 1,
              attempts,
              failed <> "retrying in #{delay} ms\n"
            )

          {true, []} ->
            {:error, {status, failed <> "retries exhausted: the registry is rate limiting pulls"}}

          {false, _delays} ->
            {:error, {status, failed <> "not retrying: the error is not a rate limit"}}
        end
    end
  end

  defp rate_limited?(output) do
    output
    |> String.downcase()
    |> String.match?(~r/\b429\b|too many requests|toomanyrequests|rate limit/)
  end

  defp output_note(output) do
    case String.trim(output) do
      "" -> ""
      text -> "\n" <> text
    end
  end

  defp decode_lines(output) do
    output
    |> String.trim()
    |> case do
      "[" <> _ = array -> Jason.decode!(array)
      lines -> lines |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end
  end
end
