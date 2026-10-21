defmodule DelivestAgent.Config do
  def get(key, default \\ nil), do: Application.get_env(:delivest_agent, key, default)

  def bastion do
    with url when is_binary(url) <- get(:bastion_url),
         token when is_binary(token) <- get(:bastion_token) do
      %{url: url, token: token}
    else
      _ -> nil
    end
  end

  def hosts,
    do: get(:hosts, %{}) |> Enum.reject(fn {_kind, host} -> is_nil(host) end) |> Map.new()

  def version, do: to_string(Application.spec(:delivest_agent, :vsn))
end
