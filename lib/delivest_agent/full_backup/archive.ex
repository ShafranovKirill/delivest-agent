defmodule DelivestAgent.FullBackup.Archive do
  @moduledoc false

  @block 512
  @outer MapSet.new(["manifest.json", "database.dump", "storage.tar"])

  def create(directory, output) do
    with {_, 0} <-
           System.cmd(
             "tar",
             [
               "--format=gnu",
               "-C",
               directory,
               "-cf",
               output,
               "manifest.json",
               "database.dump",
               "storage.tar"
             ],
             stderr_to_stdout: true
           ) do
      :ok
    else
      {message, _} -> {:error, "creating archive: #{message}"}
    end
  end

  def extract(archive, directory) do
    with :ok <- validate(archive, :outer),
         {_, 0} <- System.cmd("tar", ["-C", directory, "-xf", archive], stderr_to_stdout: true) do
      :ok
    else
      {:error, _} = error -> error
      {message, _} -> {:error, "extracting archive: #{message}"}
    end
  end

  def validate(path, kind) when kind in [:outer, :storage] do
    with {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        scan(io, kind, MapSet.new(), 0)
      after
        File.close(io)
      end
    else
      {:error, reason} -> {:error, "opening archive: #{:file.format_error(reason)}"}
    end
  end

  def digest(path) do
    with {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        digest_chunks(io, :crypto.hash_init(:sha256), 0)
      after
        File.close(io)
      end
    else
      {:error, reason} -> {:error, "reading #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp digest_chunks(io, state, size) do
    case IO.binread(io, 1_048_576) do
      :eof ->
        {:ok, %{size: size, sha256: state |> :crypto.hash_final() |> Base.encode16(case: :lower)}}

      data when is_binary(data) ->
        digest_chunks(io, :crypto.hash_update(state, data), size + byte_size(data))

      {:error, reason} ->
        {:error, "reading digest: #{inspect(reason)}"}
    end
  end

  defp scan(io, kind, names, count) do
    case IO.binread(io, @block) do
      :eof ->
        {:error, "missing tar end marker"}

      block when is_binary(block) and byte_size(block) == @block ->
        if block == :binary.copy(<<0>>, @block) do
          case IO.binread(io, @block) do
            <<0::size(4096)>> ->
              with :ok <- trailing_zeroes(io), do: finish(kind, names, count)

            _ ->
              {:error, "invalid tar end marker"}
          end
        else
          with {:ok, name, size, type} <- header(block),
               :ok <- valid_name(name, kind, type, size, names),
               :ok <- skip(io, div(size + @block - 1, @block) * @block) do
            scan(io, kind, MapSet.put(names, String.trim_trailing(name, "/")), count + 1)
          end
        end

      _ ->
        {:error, "truncated tar header"}
    end
  end

  defp finish(:outer, names, 3) do
    if names == @outer,
      do: :ok,
      else: {:error, "archive must contain exactly manifest.json, database.dump and storage.tar"}
  end

  defp finish(:outer, _names, _count), do: {:error, "archive must contain exactly three files"}

  defp finish(:storage, names, _count) do
    if MapSet.member?(names, "data"),
      do: :ok,
      else: {:error, "storage archive has no data directory"}
  end

  defp header(block) do
    <<raw_name::binary-size(100), _mode::binary-size(8), _uid::binary-size(8),
      _gid::binary-size(8), raw_size::binary-size(12), _mtime::binary-size(12),
      raw_sum::binary-size(8), type::binary-size(1), _link::binary-size(100),
      magic::binary-size(6), _version::binary-size(2), _owner::binary-size(32),
      _group::binary-size(32), _major::binary-size(8), _minor::binary-size(8),
      prefix::binary-size(155), _rest::binary>> = block

    expected =
      block
      |> binary_part(0, 148)
      |> then(&(&1 <> :binary.copy(" ", 8) <> binary_part(block, 156, 356)))
      |> :binary.bin_to_list()
      |> Enum.sum()

    with {:ok, size} <- tar_number(raw_size),
         {:ok, checksum} <- octal(raw_sum),
         true <- checksum == expected,
         true <- type in [<<0>>, "0", "5"],
         true <- magic in ["ustar\0", "ustar "] do
      name = string(raw_name)

      name =
        if magic == "ustar\0" and string(prefix) != "",
          do: string(prefix) <> "/" <> name,
          else: name

      {:ok, name, size, type}
    else
      _ -> {:error, "invalid tar header, checksum or entry type"}
    end
  end

  defp string(raw), do: raw |> :binary.split(<<0>>, [:global]) |> hd()

  defp octal(raw) do
    value = raw |> string() |> String.trim()

    case Integer.parse(value, 8) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, :invalid_octal}
    end
  end

  defp tar_number(<<first, rest::binary>>) when first >= 128 do
    <<1::1, sign::1, value::unsigned-integer-size(94)>> = <<first, rest::binary>>
    if sign == 1, do: {:error, :negative_size}, else: {:ok, value}
  end

  defp tar_number(raw), do: octal(raw)

  defp valid_name(name, kind, type, size, names) do
    parts = String.split(name, "/", trim: false)
    normalized = String.trim_trailing(name, "/")

    cond do
      name == "" or String.starts_with?(name, "/") or "\\" in String.graphemes(name) ->
        {:error, "unsafe tar path"}

      Enum.any?(Enum.drop(parts, -1), &(&1 in ["..", ".", ""])) or
          Enum.any?(parts, &(&1 in ["..", "."])) ->
        {:error, "unsafe tar path"}

      MapSet.member?(names, normalized) ->
        {:error, "duplicate tar entry"}

      type == "5" and size != 0 ->
        {:error, "directory entry has a payload"}

      type in ["0", <<0>>] and String.ends_with?(name, "/") ->
        {:error, "regular file has a directory path"}

      kind == :outer and
          (type != "0" or name not in ["manifest.json", "database.dump", "storage.tar"]) ->
        {:error, "unexpected archive entry"}

      kind == :storage and normalized == "" ->
        {:error, "unsafe tar path"}

      kind == :storage and normalized == "data" and type != "5" ->
        {:error, "storage root must be a directory"}

      kind == :storage and type == "5" and not String.ends_with?(name, "/") ->
        {:error, "noncanonical directory path"}

      kind == :storage and normalized != "data" and not String.starts_with?(normalized, "data/") ->
        {:error, "storage archive must be rooted at data/"}

      true ->
        :ok
    end
  end

  defp trailing_zeroes(io) do
    case IO.binread(io, 1_048_576) do
      :eof ->
        :ok

      bytes when is_binary(bytes) ->
        if bytes == :binary.copy(<<0>>, byte_size(bytes)),
          do: trailing_zeroes(io),
          else: {:error, "trailing tar data"}

      _ ->
        {:error, "reading tar trailer"}
    end
  end

  defp skip(_io, 0), do: :ok

  defp skip(io, bytes) do
    case IO.binread(io, min(bytes, 1_048_576)) do
      data when is_binary(data) and byte_size(data) == min(bytes, 1_048_576) ->
        skip(io, bytes - byte_size(data))

      _ ->
        {:error, "truncated tar payload"}
    end
  end
end
