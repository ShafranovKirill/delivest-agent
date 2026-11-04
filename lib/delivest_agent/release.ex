defmodule DelivestAgent.Release do
  @moduledoc """
  Keeps the state of a deployment: the release that is confirmed working, the
  previous release kept for a manual rollback, and the update that is being
  attempted right now.

  The three are stored separately in one JSON document. A failed attempt never
  overwrites the confirmed releases, so retrying an update and rolling back
  always start from the same known-good point.

  Every remembered image is tagged with a tag unique to this installation and
  release. Two installations on the same Docker host can pull images with the
  same names without overwriting each other's rollback tags.
  """

  alias DelivestAgent.{Compose, Config, MigrationLedger, Project, Runner, Status}

  @state_version 2
  @legacy_tag "delivest-previous"
  @digest ~r/@sha256:[0-9a-f]{64}\z/

  def state_path, do: Path.join(Config.get(:data_dir, "/data"), "rollback.json")

  @doc """
  A short description of the saved releases for the status page.
  """
  def rollback_info do
    case read_state() do
      {:ok, state} ->
        current = state["current"]

        %{
          "at" => current && current["at"],
          "git" => current && current["git"],
          "current" => summary(current),
          "previous" => summary(state["previous"]),
          "attempt" => summary(state["attempt"])
        }

      _error ->
        nil
    end
  end

  @doc """
  Loads the saved state and makes sure the confirmed working release exists.

  Called before an update pulls anything. The first update of an installation
  takes the running containers as its confirmed release. A previous unfinished
  attempt is discarded and the checkout is returned to the confirmed revision,
  so a retry starts from the same point as a manual rollback.
  """
  def begin_update(%Project{} = project) do
    with {:ok, state} <- load(),
         {:ok, state, log} <- ensure_current(project, state),
         {:ok, state} <- ensure_migrations(project, state),
         {:ok, state, log} <- discard_attempt(project, state, log),
         :ok <- save(state) do
      {:ok, state, log}
    else
      {:error, {_status, message}} -> {:error, message}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  @doc """
  Remembers the images an update is about to start.

  Must be called after the new revision has been pulled and before any container
  is recreated. Returns the list of target images, which the health check
  compares with what actually runs afterwards.
  """
  def record_attempt(%Project{} = project, definitions) do
    with {:ok, images} <- target_images(definitions),
         {:ok, state} <- load() do
      attempt = %{
        "at" => now(),
        "git" => git_head(project.dir),
        "images" => images
      }

      case save(Map.put(state, "attempt", attempt)) do
        :ok -> {:ok, images}
        {:error, message} -> {:error, message}
      end
    end
  end

  @doc """
  Promotes the finished attempt to the confirmed current release.

  The release that was confirmed before the update becomes the previous one for
  a manual rollback. The images of the new release get their own rollback tags
  before the state is written, so a later prune cannot remove them.
  """
  def confirm(%Project{} = project) do
    with {:ok, state} <- load(),
         {:ok, migrations} <- MigrationLedger.versions(project) do
      {attempt, capture_log} =
        case state["attempt"] do
          %{} = attempt ->
            {attempt, ""}

          _ ->
            {:ok, images} = capture(project)

            {%{"at" => now(), "git" => git_head(project.dir), "images" => images},
             "captured the running release\n"}
        end

      key = release_key(attempt)

      with {:ok, tagged} <- tag_release(project, attempt["images"], key) do
        current =
          attempt
          |> Map.put("key", key)
          |> Map.put("images", tagged)
          |> Map.put("migrations", migrations)

        state = %{state | "current" => current, "previous" => state["current"], "attempt" => nil}

        with :ok <- save(state) do
          {:ok,
           capture_log <>
             "confirmed #{describe(current)}; #{previous_note(state["previous"])}"}
        end
      end
    else
      {:error, {_status, message}} -> {:error, message}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  @doc """
  Returns the release a manual rollback must restore.
  """
  def manual_target do
    case read_state() do
      {:ok, %{"previous" => %{} = previous}} -> {:ok, previous}
      {:ok, _state} -> {:error, {1, "there is no previous release to roll back to"}}
      error -> error
    end
  end

  def guard_rollback(%Project{} = project, %{"migrations" => expected}) when is_list(expected) do
    case MigrationLedger.versions(project) do
      {:ok, ^expected} ->
        {:ok, "applied migrations match the saved release"}

      {:ok, _actual} ->
        {:error, {1, "database migrations changed; restoring the old server could be unsafe"}}

      {:error, {_status, message}} ->
        {:error, {1, "rollback safety cannot be verified: #{message}"}}
    end
  end

  def guard_rollback(_project, _release),
    do:
      {:error,
       {1, "rollback safety cannot be verified: the saved release has no migration ledger"}}

  @doc """
  Makes the release that a successful manual rollback restored the current one,
  and keeps the replaced release as the previous one.
  """
  def swap_after_rollback do
    with {:ok, state} <- load(),
         %{} = previous <- state["previous"] do
      save(%{state | "current" => previous, "previous" => state["current"], "attempt" => nil})
    else
      _ -> {:error, "the rollback state changed while it was being restored"}
    end
  end

  @doc """
  Reads a confirmed release for a rollback. Kept for callers that only need the
  document and for a clear error when the agent has not updated the site yet.
  """
  def read_state do
    case load() do
      {:ok, %{"current" => nil, "previous" => nil}} ->
        {:error, {1, "nothing to roll back to: the agent has not updated this site yet"}}

      {:ok, state} ->
        {:ok, state}

      {:error, message} ->
        {:error, {1, message}}
    end
  end

  @doc """
  Checks the images of a restored Compose revision before any service is
  recreated, and points the references at the saved release.

  Every image reference required by the restored Compose must be present with
  the saved image ID. Digest references cannot be retagged, so they must already
  resolve to the saved content. A tag that was moved by a later pull is pointed
  back at the saved image.
  """
  def restore(%Project{} = project, %{"images" => images}, definitions) do
    Enum.reduce_while(definitions, {:ok, ""}, fn definition, {:ok, log} ->
      case restore_definition(project, images, definition) do
        {:ok, output} -> {:cont, {:ok, log <> output}}
        {:error, {_status, output}} -> {:halt, {:error, {1, log <> output}}}
        {:error, output} -> {:halt, {:error, {1, log <> output}}}
      end
    end)
  end

  @doc """
  Builds the target images of a saved release for the restored Compose revision.
  """
  def target(%{"images" => images}, definitions) do
    definitions
    |> Enum.flat_map(fn %{name: name, image: ref} ->
      if is_binary(ref) and ref != "" do
        saved =
          Enum.find(images, &(&1["ref"] == ref)) ||
            Enum.find(images, &(&1["service"] == name))

        if saved,
          do: [
            %{"service" => name, "ref" => ref, "id" => saved["id"], "version" => saved["version"]}
          ],
          else: []
      else
        []
      end
    end)
  end

  @doc """
  Waits until every container runs the target images and the API and the site
  answer twice in a row. The API version must match the prepared release too,
  so an old container that still answers 200 is not taken for a successful
  update.
  """
  def wait_healthy(%Project{} = project, target \\ []) do
    timeout = Config.get(:health_timeout_ms, 300_000)
    poll = Config.get(:health_poll_ms, 5_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    started = System.monotonic_time(:millisecond)

    case wait(project, target, deadline, poll, 0) do
      :ok ->
        {:ok, "healthy after #{div(System.monotonic_time(:millisecond) - started, 1000)} s"}

      {:error, problems} ->
        {:error,
         {1,
          "not healthy after #{div(timeout, 1000)} s:\n" <>
            Enum.map_join(problems, "\n", &("- " <> &1))}}
    end
  end

  # Two good answers in a row, so a server that is still booting is not taken for a live one.
  defp wait(project, target, deadline, poll, streak) do
    problems = problems(project, target)
    streak = if problems == [], do: streak + 1, else: 0

    cond do
      streak >= 2 ->
        :ok

      System.monotonic_time(:millisecond) + poll > deadline ->
        {:error, if(problems == [], do: ["the site answered only once"], else: problems)}

      true ->
        Process.sleep(poll)
        wait(project, target, deadline, poll, streak)
    end
  end

  def problems(project, target \\ []) do
    containers = Status.containers(project)

    container_states =
      Enum.flat_map(containers, fn
        %{"error" => error} -> [error]
        %{"state" => "running"} -> []
        %{"service" => service, "state" => state} -> ["container #{service} is #{state}"]
      end)

    checks = Status.checks()

    check_problems =
      for {kind, %{"ok" => false} = check} <- checks,
          do: "#{kind} does not answer: #{check["status"] || check["error"]}"

    container_states ++
      version_problems(containers, checks) ++ image_problems(containers, target) ++ check_problems
  end

  # The agent cannot recreate its own container, so a short-lived helper from the new
  # agent image does it a few seconds after the command result has been sent.
  def start_agent_updater(%Project{} = project) do
    with {:ok, image} <- agent_image(project) do
      name = "#{project.name}_agent_updater"
      Runner.cmd("docker", ["rm", "--force", name])

      compose =
        Project.compose_args(project, [
          "up",
          "--detach",
          "--force-recreate",
          "--no-deps",
          project.agent_service
        ])

      args =
        ["run", "--detach", "--rm", "--name", name] ++
          ["--volume", "/var/run/docker.sock:/var/run/docker.sock"] ++
          ["--volume", "#{project.dir}:#{project.dir}", "--workdir", project.dir] ++
          ["--env", "PWD=#{project.dir}"] ++
          ["--entrypoint", "sh", image, "-c", ~S(sleep 5 && exec docker "$@"), "sh" | compose]

      case Runner.cmd("docker", args) do
        {_output, 0} -> {:ok, "the agent restarts with #{image} in a few seconds"}
        {output, status} -> {:error, {status, output}}
      end
    end
  end

  # The rollback tag keeps the registry path and drops the tag and digest. The
  # installation and release key make the tag private to one installation and one
  # remembered release.
  def previous_ref(ref, install \\ nil, key \\ nil) do
    ref = ref |> String.split("@") |> hd()
    {path, name} = split_last(ref, "/")
    repo = name |> String.split(":") |> hd()
    suffix = ref_suffix(install, key)
    path <> repo <> ":" <> suffix
  end

  defp ref_suffix(nil, _key), do: @legacy_tag
  defp ref_suffix(_install, nil), do: @legacy_tag

  defp ref_suffix(install, key),
    do: "delivest-" <> sanitize(install) <> "-" <> sanitize(key)

  defp sanitize(value), do: value |> to_string() |> String.replace(~r/[^A-Za-z0-9_.-]/, "-")

  defp summary(nil), do: nil

  defp summary(release) do
    %{
      "at" => release["at"],
      "git" => release["git"],
      "images" => length(release["images"] || [])
    }
  end

  defp describe(release) do
    "release #{release["git"] || release["at"]} with #{length(release["images"] || [])} images"
  end

  defp previous_note(nil), do: "there is no previous release yet"
  defp previous_note(release), do: "release #{release["git"] || release["at"]} is previous"

  defp ensure_current(_project, %{"current" => %{} = _current} = state),
    do: {:ok, state, ""}

  defp ensure_current(project, state) do
    with {:ok, images} <- capture(project) do
      release = %{"at" => now(), "git" => git_head(project.dir), "images" => images}
      key = release_key(release)

      with {:ok, tagged} <- tag_release(project, images, key) do
        current = release |> Map.put("key", key) |> Map.put("images", tagged)
        state = %{state | "current" => current, "install" => install(project)}

        {:ok, state, "remembered #{describe(current)} as the confirmed release\n"}
      end
    end
  end

  defp ensure_migrations(_project, %{"current" => %{"migrations" => migrations}} = state)
       when is_list(migrations),
       do: {:ok, state}

  defp ensure_migrations(_project, %{"attempt" => %{}}),
    do: {:error, "cannot establish a safe migration baseline for the unfinished update"}

  defp ensure_migrations(project, state) do
    with {:ok, migrations} <- MigrationLedger.versions(project) do
      {:ok, put_in(state, ["current", "migrations"], migrations)}
    end
  end

  # A previous command may have been interrupted after git moved but before the
  # new containers started. Returning the checkout to the confirmed revision
  # makes a retry behave exactly like a manual rollback.
  defp discard_attempt(_project, %{"attempt" => nil} = state, log), do: {:ok, state, log}

  defp discard_attempt(project, %{"attempt" => attempt} = state, log) do
    case git_reset(project.dir, (state["current"] || %{})["git"]) do
      {:ok, output} ->
        {:ok, %{state | "attempt" => nil},
         log <>
           "discarded the unfinished update of #{attempt["git"] || attempt["at"]}\n" <> output}

      {:error, {_status, output}} ->
        {:error, "cannot discard the unfinished update: #{String.trim(output)}"}
    end
  end

  defp capture(project) do
    with {:ok, containers} <- Compose.containers(project),
         false <- containers == [] do
      ids = Enum.map(containers, & &1["ID"])
      services = Map.new(containers, &{&1["ID"], &1["Service"]})

      format =
        ~s({{.Id}}|{{.Config.Image}}|{{.Image}}|{{index .Config.Labels "org.opencontainers.image.version"}})

      case Runner.cmd("docker", ["inspect", "--format", format | ids]) do
        {output, 0} ->
          images =
            output
            |> String.split("\n", trim: true)
            |> Enum.flat_map(fn line ->
              case String.split(line, "|", parts: 4) do
                [id, ref, image_id, version] ->
                  case service_for(services, id) do
                    nil -> []
                    service -> [image(service, ref, image_id, version)]
                  end

                _parts ->
                  []
              end
            end)
            |> Enum.reject(&(&1["service"] == project.agent_service))
            |> fill_from_definitions(project)

          {:ok, images}

        {output, status} ->
          {:error, {status, output}}
      end
    else
      true -> {:error, "no containers to remember"}
      {:error, {_status, output}} -> {:error, {1, String.trim(output)}}
    end
  end

  # A stopped service is still part of the release: `compose up` starts it again
  # together with the others. Its reference is taken from the compose file.
  defp fill_from_definitions(images, project) do
    known = MapSet.new(Enum.map(images, & &1["service"]))

    case Compose.definitions(project) do
      {:ok, definitions} ->
        definitions
        |> Enum.reject(&MapSet.member?(known, &1.name))
        |> Enum.reduce(images, fn %{name: name, image: ref}, acc ->
          if is_binary(ref) and ref != "" do
            case image_info(ref) do
              {:ok, id, version} -> acc ++ [image(name, ref, id, version)]
              {:error, _reason} -> acc
            end
          else
            acc
          end
        end)

      {:error, _reason} ->
        images
    end
  end

  defp target_images(definitions) do
    definitions
    |> Enum.reduce_while({:ok, []}, fn %{name: name, image: ref}, {:ok, images} ->
      if is_binary(ref) and ref != "" do
        case image_info(ref) do
          {:ok, id, version} ->
            {:cont, {:ok, [image(name, ref, id, version) | images]}}

          {:error, {_status, output}} ->
            {:halt,
             {:error, {1, "service #{name}: cannot inspect #{ref}: #{String.trim(output)}"}}}
        end
      else
        {:cont, {:ok, images}}
      end
    end)
    |> case do
      {:ok, images} -> {:ok, Enum.reverse(images)}
      {:error, {_status, message}} -> {:error, message}
    end
  end

  defp image_info(ref) do
    format = ~s({{.Id}}|{{index .Config.Labels "org.opencontainers.image.version"}})

    case Runner.cmd("docker", ["image", "inspect", "--format", format, ref]) do
      {output, 0} ->
        case String.split(String.trim(output), "|", parts: 2) do
          [id, version] -> {:ok, id, blank(version)}
          [id] -> {:ok, id, nil}
        end

      {output, status} ->
        {:error, {status, output}}
    end
  end

  defp image(service, ref, id, version) do
    %{
      "service" => service,
      "ref" => ref,
      "id" => id,
      "version" => blank(version)
    }
  end

  defp blank(value) when value in [nil, "", "<no value>"], do: nil
  defp blank(value), do: value

  defp service_for(services, id) do
    Enum.find_value(services, fn {short, service} ->
      if String.starts_with?(id, short), do: service
    end)
  end

  defp tag_release(project, images, key) do
    install = install(project)

    images
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, tagged} ->
      tag = previous_ref(entry["ref"], install, key)

      case Runner.cmd("docker", ["tag", entry["id"], tag]) do
        {_output, 0} -> {:cont, {:ok, [Map.put(entry, "tag", tag) | tagged]}}
        {output, status} -> {:halt, {:error, {status, output}}}
      end
    end)
    |> case do
      {:ok, tagged} -> {:ok, Enum.reverse(tagged)}
      {:error, {_status, output}} -> {:error, {1, String.trim(output)}}
    end
  end

  defp restore_definition(_project, _images, %{image: ref}) when ref in [nil, ""], do: {:ok, ""}

  defp restore_definition(_project, images, %{name: name, image: ref}) do
    local = image_id(ref)
    saved = saved_image(images, ref, local)

    cond do
      is_nil(saved) ->
        {:error, {1, "service #{name}: the saved release has no image for #{ref}"}}

      local != nil and saved["id"] != nil and local == saved["id"] ->
        {:ok, "#{ref} is still local\n"}

      Regex.match?(@digest, ref) ->
        {:error,
         {1,
          "service #{name}: #{ref} does not point at the saved image #{saved["id"]} " <>
            "(local: #{inspect(local)})"}}

      true ->
        source = saved["tag"] || saved["id"]

        with {:ok, _source_id} <- require_image_id(source, saved),
             {_output, 0} <- Runner.cmd("docker", ["tag", source, ref]) do
          {:ok, "#{ref} <- #{source}\n"}
        else
          {:error, {_status, output}} ->
            {:error, {1, "service #{name}: cannot restore #{ref}: #{String.trim(output)}"}}

          {:error, message} ->
            {:error, {1, "service #{name}: #{message}"}}
        end
    end
  end

  defp require_image_id(source, %{"id" => saved_id} = saved) do
    case image_id(source) do
      nil ->
        {:error, "the saved image #{inspect(source)} for #{saved["ref"]} is not local anymore"}

      id when id != saved_id ->
        {:error, "the rollback tag #{source} points at #{id}, but the release saved #{saved_id}"}

      id ->
        {:ok, id}
    end
  end

  defp saved_image(images, ref, local) do
    Enum.find(images, &(&1["ref"] == ref)) ||
      if(is_binary(local), do: Enum.find(images, &(&1["id"] == local)))
  end

  defp image_id(ref) do
    case Runner.cmd("docker", ["image", "inspect", "--format", "{{.Id}}", ref]) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> nil
    end
  end

  defp version_problems(containers, checks) do
    versions =
      containers
      |> Enum.flat_map(fn
        %{"service" => service, "version" => version} when is_binary(version) ->
          [{service, version}]

        _container ->
          []
      end)
      |> Map.new()

    expected = versions["server"]
    api = checks["api"]

    cond do
      is_binary(expected) and match?(%{"ok" => true}, api) and
        is_binary(api["version"]) and api["version"] != expected ->
        [
          "api answers version #{api["version"]}, but the server container runs #{expected}"
        ]

      is_binary(expected) and match?(%{"ok" => true}, api) and is_nil(api["version"]) ->
        ["api did not name its version, the server container runs #{expected}"]

      true ->
        []
    end
  end

  defp image_problems(_containers, []), do: []

  defp image_problems(containers, target) do
    by_service = Map.new(containers, &{&1["service"], &1})

    Enum.flat_map(target, fn image ->
      case Map.get(by_service, image["service"]) do
        nil ->
          ["container #{image["service"]} is not running"]

        container ->
          image_problem(container, image) ++ version_problem(container, image)
      end
    end)
  end

  defp image_problem(container, image) do
    actual = container["image_id"]
    expected = image["id"]

    if is_binary(actual) and is_binary(expected) and actual != expected,
      do: [
        "container #{image["service"]} runs image #{actual}, expected #{expected}"
      ],
      else: []
  end

  defp version_problem(container, image) do
    actual = container["version"]
    expected = image["version"]

    if is_binary(actual) and is_binary(expected) and actual != expected,
      do: [
        "container #{image["service"]} runs version #{actual}, expected #{expected}"
      ],
      else: []
  end

  defp agent_image(project) do
    with {:ok, containers} <- Compose.ps(project) do
      case Enum.find(containers, &(&1["Service"] == project.agent_service)) do
        %{"Image" => image} when is_binary(image) -> {:ok, image}
        _ -> {:error, {1, "the agent container is not found"}}
      end
    end
  end

  defp git_head(dir) do
    case git(dir, ["rev-parse", "HEAD"]) do
      {:ok, sha} -> String.trim(sha)
      _ -> nil
    end
  end

  defp git_reset(_dir, nil), do: {:ok, ""}

  defp git_reset(dir, sha) do
    case git(dir, ["reset", "--keep", sha]) do
      {:ok, output} -> {:ok, output}
      {:error, {_status, output}} -> {:error, {1, output}}
    end
  end

  defp git(dir, args) do
    if File.exists?(Path.join(dir, ".git")) do
      {command, args} = as_owner(dir, ["git", "-C", dir | args])

      case Runner.cmd(command, args) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, {status, output}}
      end
    else
      {:error, {1, "not a git checkout"}}
    end
  end

  defp as_owner(dir, [command | args]) do
    case File.stat(dir) do
      {:ok, %{uid: uid, gid: gid}} when uid != 0 ->
        {"setpriv",
         ["--reuid", to_string(uid), "--regid", to_string(gid), "--clear-groups"] ++
           ["env", "HOME=/tmp", command | args]}

      _ ->
        {command, args}
    end
  end

  defp release_key(%{"git" => git, "at" => at}) do
    sha =
      case git do
        value when is_binary(value) and value != "" ->
          binary_part(value, 0, min(12, byte_size(value)))

        _ ->
          "nogit"
      end

    time =
      at
      |> to_string()
      |> String.replace(~r/[^0-9]/, "")
      |> String.slice(0, 14)

    sha <> "-" <> time
  end

  defp install(%Project{} = project), do: project.name

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp split_last(ref, separator) do
    case String.split(ref, separator) do
      [name] -> {"", name}
      parts -> {Enum.join(Enum.drop(parts, -1), separator) <> separator, List.last(parts)}
    end
  end

  # --- state file ---------------------------------------------------------

  defp load do
    case File.read(state_path()) do
      {:ok, content} ->
        with {:ok, document} <- Jason.decode(content) do
          normalize(document)
        else
          {:error, reason} ->
            {:error, "the rollback state is corrupt: #{Exception.message(reason)}"}
        end

      {:error, :enoent} ->
        {:ok, empty_state()}

      {:error, reason} ->
        {:error, "cannot read the rollback state: #{:file.format_error(reason)}"}
    end
  end

  defp normalize(%{"version" => @state_version} = state) do
    with true <- valid_release?(state["current"]),
         true <- valid_release?(state["previous"]),
         true <- valid_release?(state["attempt"]) do
      {:ok,
       %{
         "version" => @state_version,
         "install" => state["install"],
         "current" => state["current"],
         "previous" => state["previous"],
         "attempt" => state["attempt"]
       }}
    else
      _ -> {:error, "the rollback state is incomplete"}
    end
  end

  # The previous format kept only the state before the last update. It becomes
  # the previous release: the running containers are captured as the current one
  # on the next update.
  defp normalize(%{"images" => images} = legacy) when is_list(images) do
    release = %{
      "at" => legacy["at"],
      "git" => legacy["git"],
      "key" => "legacy",
      "images" => images
    }

    {:ok,
     %{
       "version" => @state_version,
       "install" => nil,
       "current" => nil,
       "previous" => release,
       "attempt" => nil
     }}
  end

  defp normalize(_document), do: {:error, "the rollback state is incomplete"}

  defp valid_release?(nil), do: true

  defp valid_release?(%{"images" => images} = release) when is_list(images) do
    is_nil(release["git"]) or is_binary(release["git"])
  end

  defp valid_release?(_release), do: false

  defp empty_state do
    %{
      "version" => @state_version,
      "install" => nil,
      "current" => nil,
      "previous" => nil,
      "attempt" => nil
    }
  end

  # A rename within the data directory is atomic: a crash leaves either the old
  # document or the new one, never a partially written file.
  defp save(state) do
    path = state_path()
    temporary = path <> ".tmp"
    document = Jason.encode!(state)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, file} <- File.open(temporary, [:write, :binary, :sync]),
         :ok <- IO.binwrite(file, document),
         :ok <- File.close(file),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, "cannot save the rollback state: #{:file.format_error(reason)}"}
    end
  end
end
