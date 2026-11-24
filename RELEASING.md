# Releasing

Typsty's NIF, and the `typsty_worker` program `Typsty.Pool` runs, are precompiled for each
target by the `Build precompiled NIFs` workflow (`.github/workflows/release.yml`), and
RustlerPrecompiled downloads them from the GitHub release of the version. Each target's
tarball holds both: RustlerPrecompiled checks the tarball against its checksum and extracts
all of it into `priv/native`, which puts the worker next to the NIF. The tarballs are built
by `.github/scripts/build-native.sh`, which also works locally for the machine's own target:

```shell
.github/scripts/build-native.sh aarch64-apple-darwin 2.15 0.1.0
```

Building needs Rust 1.92 or later (the version in `.tool-versions`), which Typst 0.15
requires.

## Before the first release, and after changing the workflow

Run the `Build precompiled NIFs` workflow by hand (Actions, then "Run workflow") on
`master`. Without a tag it builds every target and uploads the tarballs as artifacts of the
run, without publishing anything, so problems show up before a version is tagged. Check that
every job passed and uploaded a tarball.

## Releasing a version

The Hex package includes a checksum file for the builds, so a release happens in this
order:

1. Set the version in `VERSION` (such as `0.1.0`, without `-dev`) and move the
   `Unreleased` entries in `CHANGELOG.md` under it, with the date. Merge that to `master`.
   Until the release's builds are published, a git dependency on `master` can't download
   them; that's fine for the few minutes the release takes.
2. Tag the merge commit with the version and push the tag:

   ```shell
   git tag 0.1.0
   git push origin 0.1.0
   ```

   The workflow builds the NIF and the worker for every target and attaches the tarballs
   to the tag's GitHub release. It fails if the tag doesn't match `VERSION`. If a job fails,
   fix the cause and re-run the failed jobs: the tarballs already attached stay.
3. Once all 8 tarballs are attached, generate the checksum file from them:

   ```shell
   TYPSTY_BUILD=1 mix do compile --force + rustler_precompiled.download Typsty.Native --all --print
   ```

   This writes `checksum-Elixir.Typsty.Native.exs`. `TYPSTY_BUILD=1` lets the project
   compile before the checksum file exists, and `--force` recompiles `Typsty.Native` with
   the new version, so that it downloads the new version's tarballs.
4. Check the package before publishing it: `mix hex.build --unpack` writes it to a
   directory, which a scratch project can depend on with `path:` to install the precompiled
   NIF and render a document.
5. Publish to Hex with `mix hex.publish`. The checksum file is part of the package. Until
   it exists, `mix hex.build` and `mix hex.publish` stop with
   `Missing files: checksum-*.exs`, so a package can't go out without it.
6. Commit the checksum file, so that a git dependency on the tag finds it too.
7. Set `VERSION` to the next development version (such as `0.2.0-dev`). Development
   versions always build the NIF and the worker from source.
