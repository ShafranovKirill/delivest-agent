import Config

config :delivest_agent,
  runner: DelivestAgent.FakeRunner,
  start_bastion: false,
  health_timeout_ms: 50,
  health_poll_ms: 10,
  data_dir: Path.expand("../tmp/test-data", __DIR__)

config :logger, level: :warning
