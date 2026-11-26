# Releasing

Typsty's NIF, and the `typsty_worker` program `Typsty.Pool` runs, are precompiled for each
target by the `Build precompiled NIFs` workflow (`.github/workflows/release.yml`), and
RustlerPrecompiled downloads them from the GitHub release of the version. Each target's
tarball holds both, with Typsty's license and `THIRD_PARTY_NOTICES.txt` (as `typsty-LICENSE.txt`
and `typsty-THIRD_PARTY_NOTICES.txt`): RustlerPrecompiled
checks the tarball against its checksum and extracts all of it into `priv/native`, which
puts the worker next to the NIF. The tarballs are built by `.github/scripts/build-native.sh`,
which also works locally for the machine's own target:

```shell
.github/scripts/build-native.sh aarch64-apple-darwin 2.15 0.1.0
```

Building needs Rust 1.92 or later (the version in `.tool-versions`), which Typst 0.15
requires.

## When the Rust dependencies change

`THIRD_PARTY_NOTICES.txt` lists the licenses of the crates the binaries are built from. CI
checks that it's up to date; after changing `native/Cargo.lock`, regenerate it:

```shell
elixir .github/scripts/third_party_notices.exs
```

## Before the first release, and after changing the release workflow

CI uploads test coverage to Coveralls, which fails until the repository is enabled on
coveralls.io: enable it before the first merge to `master`.

Run the `Build precompiled NIFs` workflow by hand (Actions, then "Run workflow") on
`master`. Without a tag, it builds every target and uploads the tarballs as artifacts of the
run, without publishing anything, so problems show up before a version is tagged. Check
that all 8 jobs passed: each one smoke-tests the worker where the runner can run it, and the
Linux job shows the newest glibc version the binaries need.

## Releasing a version

The Hex package includes a checksum file for the builds, so a release happens in this
order:

1. Set the version in `VERSION` (such as `0.1.0`, without `-dev`), move the `Unreleased`
   entries in `CHANGELOG.md` under it, with the date, and update the version in the
   README's installation instructions. Merge that to `master`, and wait for its CI run to
   pass. Until the release's builds are published, a dependency on `master` can't download
   them; that's fine for the few minutes the release takes.
2. Tag the merge commit with the version and push the tag:

   ```shell
   git tag 0.1.0
   git push origin 0.1.0
   ```

   The workflow builds the NIF and the worker for every target and attaches the tarballs
   to the tag's GitHub release. It fails if the tag doesn't match `VERSION`. If a job fails
   for a passing reason (a network hiccup), re-run the failed jobs. If it needs a change to
   the code, and nothing was published to Hex yet, delete the GitHub release and the tag,
   merge the fix, and tag the new merge commit; once a version is on Hex, release the next
   patch version instead.
3. Once all 8 tarballs are attached, generate the checksum file from them, on the tagged
   commit:

   ```shell
   TYPSTY_BUILD=1 CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
     mix do compile --force + rustler_precompiled.download Typsty.Native --all --print
   ```

   This writes `checksum-Elixir.Typsty.Native.exs`; check that it has 8 entries.
   `TYPSTY_BUILD=1` lets the project compile before the checksum file exists (the
   `CARGO_PROFILE_*` variables make that build quicker), and `--force` recompiles
   `Typsty.Native` with the new version, so that it downloads the new version's tarballs.
4. Check the package before publishing it:

   ```shell
   mix hex.build --unpack --output /tmp/typsty-0.1.0
   ```

   In a scratch project that depends on it with `path: "/tmp/typsty-0.1.0"`, compile
   without Rust and with an empty download cache, so that the NIF and the worker really
   are downloaded from the release (and checked against the checksum file):

   ```shell
   RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=$(mktemp -d) mix compile
   ```

   Then render a document, inside the VM and in a `Typsty.Pool`.
5. Publish to Hex with `mix hex.publish`, which publishes the docs too. The checksum file
   is part of the package (and ignored by git: a git dependency on a release's tag builds
   the NIF from source, with `TYPSTY_BUILD=1`). Until it exists, `mix hex.build` and
   `mix hex.publish` stop with `Missing files: checksum-*.exs`, so a package can't go out
   without it.
6. Set `VERSION` to the next development version (such as `0.2.0-dev`), and start a new
   `Unreleased` section in `CHANGELOG.md`. Development versions always build the NIF and
   the worker from source.
