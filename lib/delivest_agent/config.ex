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

  # The site cannot work without an API and a storefront host: the API serves the
  # application and the site is what a client opens. Both are required in every
  # supported configuration. The S3 host is optional.
  @required_hosts ~w(api site)

  def required_hosts, do: @required_hosts

  def hosts,
    do: get(:hosts, %{}) |> Enum.reject(fn {_kind, host} -> is_nil(host) end) |> Map.new()

  def host(kind), do: Map.get(hosts(), kind)

  def config_errors, do: Enum.map(missing_hosts(), &"#{&1} host is not configured")

  def missing_hosts, do: Enum.reject(@required_hosts, &is_binary(host(&1)))

  def version, do: to_string(Application.spec(:delivest_agent, :vsn))
end
