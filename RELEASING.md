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

The Hex package includes a checksum file for those builds, so a release happens in this
order:

1. Set the version in `VERSION` (such as `0.1.0`, without `-dev`) and move the
   `Unreleased` entries in `CHANGELOG.md` under it. Merge that to `master`.
2. Tag the merge commit with the version and push the tag:

   ```shell
   git tag 0.1.0
   git push origin 0.1.0
   ```

   The workflow builds the NIF and the worker for every target and attaches the tarballs
   to the tag's GitHub release. It fails if the tag doesn't match `VERSION`.
3. Once every build is attached, generate the checksum file from them:

   ```shell
   TYPSTY_BUILD=1 mix rustler_precompiled.download Typsty.Native --all --print
   ```

   This writes `checksum-Elixir.Typsty.Native.exs`. `TYPSTY_BUILD=1` lets the project
   compile before the checksum file exists.
4. Publish to Hex with `mix hex.publish`. The checksum file is part of the package (it
   doesn't need to be committed). Until it exists, `mix hex.build` and `mix hex.publish`
   stop with `Missing files: checksum-*.exs`, so a package can't go out without it.
5. Set `VERSION` to the next development version (such as `0.2.0-dev`). Development
   versions always build the NIF and the worker from source.
