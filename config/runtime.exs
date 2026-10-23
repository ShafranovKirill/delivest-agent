import Config

blank_to_nil = fn
  nil -> nil
  value -> if String.trim(value) == "", do: nil, else: String.trim(value)
end

if config_env() != :test do
  config :delivest_agent,
    bastion_url: blank_to_nil.(System.get_env("BASTION_URL")),
    bastion_token: blank_to_nil.(System.get_env("BASTION_TOKEN")),
    instance_name: blank_to_nil.(System.get_env("INSTANCE_NAME")),
    data_dir: System.get_env("AGENT_DATA_DIR", "/data"),
    gateway_url: System.get_env("AGENT_GATEWAY_URL", "http://gateway"),
    heartbeat_ms: String.to_integer(System.get_env("AGENT_HEARTBEAT_SECONDS", "30")) * 1000,
    health_timeout_ms:
      String.to_integer(System.get_env("AGENT_UPDATE_HEALTH_SECONDS", "300")) * 1000,
    hosts: %{
      "api" => blank_to_nil.(System.get_env("PHX_HOST")),
      "site" =>
        with(
          origin when is_binary(origin) <- blank_to_nil.(System.get_env("CLIENT_ORIGIN")),
          do: URI.parse(origin).host
        ),
      "s3" => blank_to_nil.(System.get_env("S3_PUBLIC_HOST"))
    }
end
