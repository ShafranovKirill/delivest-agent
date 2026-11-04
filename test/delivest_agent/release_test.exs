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

  test "two installations and two releases get different rollback tags" do
    tag = Release.previous_ref("ghcr.io/x/delivest-server:latest", "shop-a", "abc123-20261104")

    assert tag == "ghcr.io/x/delivest-server:delivest-shop-a-abc123-20261104"

    refute tag ==
             Release.previous_ref("ghcr.io/x/delivest-server:latest", "shop-b", "abc123-20261104")

    refute tag ==
             Release.previous_ref("ghcr.io/x/delivest-server:latest", "shop-a", "def456-20261105")

    assert Release.previous_ref("nginx", "shop a", "release/1") ==
             "nginx:delivest-shop-a-release-1"
  end
end
