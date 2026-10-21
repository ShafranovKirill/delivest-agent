defmodule DelivestAgent.Runner do
  @callback cmd(command :: String.t(), args :: [String.t()]) :: {String.t(), non_neg_integer()}

  def cmd(command, args), do: DelivestAgent.Config.get(:runner).cmd(command, args)
end
