defmodule DelivestAgent.Identity do
  alias DelivestAgent.Config

  def instance_id do
    path = Path.join(Config.get(:data_dir, "/data"), "instance_id")

    case File.read(path) do
      {:ok, id} when byte_size(id) > 0 ->
        String.trim(id)

      _ ->
        id = generate()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, id)
        id
    end
  end

  defp generate do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [
      a,
      b,
      Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000),
      Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000),
      e
    ]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {value, size} ->
      value |> Integer.to_string(16) |> String.pad_leading(size, "0") |> String.downcase()
    end)
  end
end
