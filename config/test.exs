import Config

config :delivest_agent, runner: DelivestAgent.FakeRunner, start_bastion: false
config :logger, level: :warning
