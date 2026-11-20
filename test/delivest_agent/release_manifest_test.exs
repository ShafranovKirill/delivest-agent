defmodule DelivestAgent.ReleaseManifestTest do
  use ExUnit.Case, async: true
  alias DelivestAgent.ReleaseManifest

  @sha String.duplicate("a", 40)
  @digest "sha256:" <> String.duplicate("b", 64)
  @manifest %{
    "version" => "1.2.3",
    "root_sha" => @sha,
    "gitlinks" => Map.new(~w(server client agent), &{&1, @sha}),
    "images" => Map.new(~w(server client agent), &{&1, @digest})
  }

  test "accepts exact release manifest and builds fixed registry references" do
    assert {:ok, @manifest} = ReleaseManifest.validate(@manifest)

    assert ReleaseManifest.ref(@manifest, "server") ==
             "ghcr.io/shafranovkirill/delivest-server@#{@digest}"
  end

  test "rejects missing or malformed content and extra names" do
    assert {:error, _} = ReleaseManifest.validate(put_in(@manifest, ["images", "server"], nil))

    assert {:error, _} =
             ReleaseManifest.validate(put_in(@manifest, ["images", "server"], "sha256:ABC"))

    assert {:error, _} =
             ReleaseManifest.validate(put_in(@manifest, ["gitlinks", "server"], "HEAD"))

    assert {:error, _} =
             ReleaseManifest.validate(Map.put(@manifest, "repository", "attacker/repo"))
  end
end
