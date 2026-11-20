defmodule DelivestAgent.ReleaseManifest do
  @moduledoc "Validates the immutable release selected by Bastion."

  @sha ~r/\A[0-9a-f]{40}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  @version ~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\z/
  @components ~w(server client agent)

  def validate(
        %{"version" => version, "root_sha" => root, "gitlinks" => links, "images" => images} =
          manifest
      )
      when is_binary(version) and is_binary(root) and is_map(links) and is_map(images) do
    if Regex.match?(@version, version) and Regex.match?(@sha, root) and
         Enum.sort(Map.keys(links)) == Enum.sort(@components) and
         Enum.sort(Map.keys(images)) == Enum.sort(@components) and
         Enum.all?(@components, fn component ->
           is_binary(links[component]) and Regex.match?(@sha, links[component]) and
             is_binary(images[component]) and Regex.match?(@digest, images[component])
         end) and Enum.sort(Map.keys(manifest)) == ~w(gitlinks images root_sha version) do
      {:ok, manifest}
    else
      {:error, "invalid release manifest: expected version, root SHA, gitlinks and three digests"}
    end
  end

  def validate(_),
    do:
      {:error, "invalid release manifest: expected version, root SHA, gitlinks and three digests"}

  def ref(manifest, component) when component in @components do
    "ghcr.io/shafranovkirill/delivest-#{component}@#{manifest["images"][component]}"
  end

  def refs(manifest), do: Map.new(@components, &{&1, ref(manifest, &1)})
end
