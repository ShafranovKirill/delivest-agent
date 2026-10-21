defmodule DelivestAgent.Env do
  alias DelivestAgent.Project

  @max_size 256_000

  def path(%Project{dir: dir}), do: Path.join(dir, ".env")

  def read(%Project{} = project) do
    case File.read(path(project)) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, "cannot read .env: #{:file.format_error(reason)}"}
    end
  end

  def write(%Project{}, content) when is_binary(content) and byte_size(content) > @max_size,
    do: {:error, {1, ".env is larger than #{@max_size} bytes"}}

  def write(%Project{} = project, content) when is_binary(content) do
    path = path(project)
    tmp = path <> ".tmp"
    owner = owner(path, project.dir)
    content = normalize(content)

    with :ok <- backup(path, owner),
         :ok <- File.write(tmp, content),
         :ok <- apply_owner(tmp, owner),
         :ok <- File.rename(tmp, path) do
      {:ok, "saved #{byte_size(content)} bytes, the previous version is in .env.bak"}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {1, "cannot write .env: #{:file.format_error(reason)}"}}
    end
  end

  def write(%Project{}, _content), do: {:error, {1, "content is required"}}

  defp normalize(content) do
    content = String.replace(content, "\r\n", "\n")
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
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
