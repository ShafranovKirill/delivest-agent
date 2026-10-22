import Config

config :delivest_agent,
  runner: DelivestAgent.FakeRunner,
  start_bastion: false,
  data_dir: Path.expand("../tmp/test-data", __DIR__)

config :logger, level: :warning
