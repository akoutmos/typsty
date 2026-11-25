# Writes THIRD_PARTY_NOTICES.txt: the licenses and notices of the Rust crates Typsty's NIF
# and worker are built from (Typst, typstyle and their dependencies, and the fonts Typst
# embeds), which the precompiled binaries must ship with.
#
# Run it from the repository's root after changing native/Cargo.lock:
#
#     elixir .github/scripts/third_party_notices.exs
#
# With --check, it only fails if the file is out of date.

{:ok, _} = Application.ensure_all_started(:crypto)

check? = "--check" in System.argv()
output = "THIRD_PARTY_NOTICES.txt"

{json, 0} =
  System.cmd("cargo", ~w(metadata --format-version 1 --locked --manifest-path native/Cargo.toml))

metadata = JSON.decode!(json)
packages = Map.new(metadata["packages"], &{&1["id"], &1})
nodes = Map.new(metadata["resolve"]["nodes"], &{&1["id"], &1})
members = MapSet.new(metadata["workspace_members"])

# The crates the NIF and the worker depend on, without build and dev dependencies, which
# aren't part of the binaries
reachable = fn reachable, [id | rest], seen ->
  if MapSet.member?(seen, id) do
    reachable.(reachable, rest, seen)
  else
    deps =
      for dep <- nodes[id]["deps"],
          Enum.any?(dep["dep_kinds"], &(&1["kind"] == nil)),
          do: dep["pkg"]

    reachable.(reachable, deps ++ rest, MapSet.put(seen, id))
  end

  _reachable, [], seen -> seen
end

crates =
  reachable.(reachable, MapSet.to_list(members), MapSet.new())
  |> Enum.reject(&MapSet.member?(members, &1))
  |> Enum.map(&packages[&1])
  |> Enum.sort_by(&{&1["name"], &1["version"]})

license_file? = fn name ->
  String.match?(name, ~r/^(licen[cs]e|copying|copyright|notice|unlicense)([-._].*)?$/i)
end

# Each crate's own license and notice files, from its directory in the Cargo registry
texts =
  for crate <- crates,
      dir = Path.dirname(crate["manifest_path"]),
      file <- dir |> File.ls!() |> Enum.filter(license_file?) |> Enum.sort(),
      File.regular?(Path.join(dir, file)) do
    text = dir |> Path.join(file) |> File.read!() |> String.replace("\r\n", "\n") |> String.trim()
    {text, "#{crate["name"]} #{crate["version"]} (#{file})"}
  end
  |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  |> Enum.sort_by(fn {_text, users} -> hd(users) end)

with_files = for {_text, users} <- texts, user <- users, into: MapSet.new(), do: user |> String.split(" ") |> hd()

# Crates without license files are used under the Apache License 2.0, whose text another
# crate ships, or under a license that needs no notice
{apache_text, apache_users} =
  Enum.find(texts, fn {text, _users} -> String.match?(text, ~r/\A\s*Apache License\s+Version 2\.0/) end)

no_notice = ~w(0BSD CC0-1.0 Unlicense)

without_files =
  for crate <- crates, not MapSet.member?(with_files, crate["name"]) do
    license = crate["license"] || ""

    cond do
      String.contains?(license, "Apache-2.0") ->
        :ok

      Enum.any?(no_notice, &String.contains?(license, &1)) ->
        :ok

      true ->
        IO.puts(:stderr, "warning: #{crate["name"]} #{crate["version"]} (#{license}) has no license file to include")
    end

    crate
  end

_ = apache_text

notices =
  [
    """
    Third-party software in Typsty's precompiled NIF and worker
    ===========================================================

    Typsty's native code (typsty_nif and typsty_worker) is built from these Rust crates, which
    are distributed under the licenses below. Typsty itself is under the MIT license (LICENSE).

    """,
    for crate <- crates do
      missing = if crate in without_files, do: " (no license file in the crate: see below)", else: ""
      "- #{crate["name"]} #{crate["version"]}: #{crate["license"] || "unknown"}#{missing}\n"
    end,
    """

    The crates without a license file of their own are used under the Apache License 2.0,
    whose text is below, with #{hd(apache_users)}, or under a license that needs no notice
    (#{Enum.join(no_notice, ", ")}).
    """,
    for {text, users} <- texts do
      [
        "\n",
        String.duplicate("=", 80),
        "\n\n",
        Enum.map(users, &"#{&1}\n"),
        "\n",
        text,
        "\n"
      ]
    end
  ]
  |> IO.iodata_to_binary()

cond do
  not check? ->
    File.write!(output, notices)
    IO.puts("Wrote #{output} (#{length(crates)} crates, #{length(texts)} distinct texts)")

  File.read(output) == {:ok, notices} ->
    IO.puts("#{output} is up to date")

  true ->
    IO.puts(:stderr, "#{output} is out of date: run elixir .github/scripts/third_party_notices.exs")
    System.halt(1)
end
