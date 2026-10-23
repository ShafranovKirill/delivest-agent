defmodule DelivestAgent.ReleaseTest do
  use ExUnit.Case, async: true

  alias DelivestAgent.Release

  test "the previous tag keeps the registry path and drops the tag and digest" do
    assert Release.previous_ref("ghcr.io/x/delivest-server:latest") ==
             "ghcr.io/x/delivest-server:delivest-previous"

    assert Release.previous_ref("localhost:5000/app@sha256:abc") ==
             "localhost:5000/app:delivest-previous"

    assert Release.previous_ref("nginx") == "nginx:delivest-previous"
  end
end
