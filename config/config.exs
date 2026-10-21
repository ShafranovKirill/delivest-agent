import Config

config :delivest_agent, runner: DelivestAgent.Shell

import_config "#{config_env()}.exs"
