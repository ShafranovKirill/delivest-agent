defmodule DelivestAgent.Env do
  alias DelivestAgent.Project

  @max_size 256_000
  @image_keys ~w(DELIVEST_SERVER_IMAGE DELIVEST_CLIENT_IMAGE DELIVEST_AGENT_IMAGE)

  def path(%Project{dir: dir}), do: Path.join(dir, ".env")

  def read(%Project{} = project) do
    case File.read(path(project)) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, "cannot read .env: #{:file.format_error(reason)}"}
    end
  end

  # Only the names of the variables leave the server, never their values.
  def check(%Project{dir: dir} = project) do
    case File.read(Path.join(dir, ".env.example")) do
      {:ok, example} ->
        present =
          case File.read(path(project)) do
            {:ok, content} -> keys(content)
            _ -> []
          end

        %{"missing" => Enum.reject(keys(example), &(&1 in present))}

      _ ->
        nil
    end
  end

  def keys(content) do
    content
    |> String.split(["\r\n", "\n"])
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/, line) do
        [_, key] -> [key]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  def write(%Project{}, content) when is_binary(content) and byte_size(content) > @max_size,
    do: {:error, {1, ".env is larger than #{@max_size} bytes"}}

  def write(%Project{} = project, content) when is_binary(content) do
    path = path(project)
    tmp = path <> ".tmp"
    owner = owner(path, project.dir)
    content = preserve_image_refs(project, normalize(content))

    with :ok <- backup(path, owner),
         :ok <- secure_write(tmp, content, owner),
         :ok <- File.rename(tmp, path) do
      {:ok, "saved #{byte_size(content)} bytes, the previous version is in .env.bak"}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {1, "cannot write .env: #{:file.format_error(reason)}"}}
    end
  end

  def write(%Project{}, _content), do: {:error, {1, "content is required"}}

  # These assignments are the durable Compose selection. They live in the default
  # Compose .env so a normal operator `docker compose up` uses the selected release.
  def select_images(%Project{} = project, refs) when is_map(refs) do
    with {:ok, content} <- read(project),
         true <-
           map_size(refs) > 0 and
             Enum.all?(refs, fn {key, value} ->
               key in ~w(server client agent) and is_binary(value)
             end) do
      existing =
        case image_refs(project) do
          {:ok, refs} -> refs
          _ -> %{}
        end

      selected_refs =
        Map.merge(
          existing,
          Map.new(refs, fn {key, value} -> {"DELIVEST_#{String.upcase(key)}_IMAGE", value} end)
        )

      selected =
        Enum.map_join(selected_refs, "\n", fn {key, value} -> "#{key}=#{value}" end)

      write_raw(project, strip_image_refs(content) <> selected <> "\n")
    else
      false -> {:error, {1, "invalid image references"}}
      error -> error
    end
  end

  def image_refs(%Project{} = project) do
    with {:ok, content} <- read(project) do
      refs =
        content
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, "=", parts: 2) do
            [key, value] when key in @image_keys -> Map.put(acc, key, value)
            _ -> acc
          end
        end)

      {:ok, refs}
    end
  end

  def restore_image_refs(%Project{} = project, refs) when is_map(refs) do
    with {:ok, content} <- read(project) do
      assignments = Enum.map_join(refs, "\n", fn {key, value} -> "#{key}=#{value}" end)
      suffix = if assignments == "", do: "", else: assignments <> "\n"
      write_raw(project, strip_image_refs(content) <> suffix)
    end
  end

  def restore_site_refs(%Project{} = project, refs) when is_map(refs) do
    with {:ok, current} <- image_refs(project) do
      restore_image_refs(
        project,
        Map.merge(
          Map.take(current, ["DELIVEST_AGENT_IMAGE"]),
          Map.take(refs, ["DELIVEST_SERVER_IMAGE", "DELIVEST_CLIENT_IMAGE"])
        )
      )
    end
  end

  defp preserve_image_refs(project, content) do
    case image_refs(project) do
      {:ok, refs} ->
        suffix = Enum.map_join(refs, "\n", fn {key, value} -> "#{key}=#{value}" end)
        strip_image_refs(content) <> if(suffix == "", do: "", else: suffix <> "\n")

      _ ->
        content
    end
  end

  defp strip_image_refs(content) do
    content
    |> String.split("\n")
    |> Enum.reject(fn line -> Enum.any?(@image_keys, &String.starts_with?(line, &1 <> "=")) end)
    |> Enum.join("\n")
    |> normalize()
  end

  defp write_raw(project, content) do
    path = path(project)
    tmp = path <> ".tmp"
    owner = owner(path, project.dir)

    with :ok <- secure_write(tmp, normalize(content), owner),
         :ok <- File.rename(tmp, path) do
      {:ok, "selected Compose image references"}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {1, "cannot save Compose image references: #{:file.format_error(reason)}"}}
    end
  end

  defp normalize(content) do
    content = String.replace(content, "\r\n", "\n")
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end

  defp secure_write(path, content, owner) do
    with {:ok, file} <- File.open(path, [:write, :binary, :sync]),
         :ok <- apply_owner(path, owner) do
      result = IO.binwrite(file, content)
      File.close(file)
      result
    end
  end

  defp backup(path, owner) do
    backup = path <> ".bak"

    case File.cp(path, backup) do
      :ok -> apply_owner(backup, owner)
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp owner(path, dir) do
    case File.stat(path) do
      {:ok, %{uid: uid, gid: gid, mode: mode}} ->
        {uid, gid, Bitwise.band(mode, 0o777)}

      _ ->
        %{uid: uid, gid: gid} = File.stat!(dir)
        {uid, gid, 0o600}
    end
  end

  defp apply_owner(path, {uid, gid, mode}) do
    with :ok <- File.chmod(path, mode),
         :ok <- chown(path, uid, gid),
         do: :ok
  end

  defp chown(path, uid, gid) do
    case File.stat(path) do
      {:ok, %{uid: ^uid, gid: ^gid}} -> :ok
      _ -> with :ok <- File.chown(path, uid), do: File.chgrp(path, gid)
    end
  end
end
