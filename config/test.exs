import Config

config :delivest_agent,
  runner: DelivestAgent.FakeRunner,
  start_bastion: false,
  health_timeout_ms: 1_000,
  health_poll_ms: 10,
  pull_retry_delays_ms: [0, 0],
  data_dir: Path.expand("../tmp/test-data", __DIR__)

config :logger, level: :warning
