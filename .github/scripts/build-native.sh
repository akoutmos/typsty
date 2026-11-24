#!/usr/bin/env bash
#
# Builds Typsty's NIF and its worker program (for Typsty.Pool) for a target, and packages
# them the way RustlerPrecompiled downloads NIFs: a tarball named after the NIF, which
# RustlerPrecompiled checks against its checksum and extracts whole into priv/native, so the
# worker arrives next to the NIF.
#
# Usage: .github/scripts/build-native.sh TARGET NIF_VERSION VERSION [USE_CROSS]
#
#   .github/scripts/build-native.sh aarch64-apple-darwin 2.15 0.1.0
#   .github/scripts/build-native.sh aarch64-unknown-linux-gnu 2.15 0.1.0 true
#
# The tarball is written to dist/, and its path is the last line of the output.

set -euo pipefail

target="$1"
nif_version="$2"
version="$3"
use_cross="${4:-false}"

root="$(cd "$(dirname "$0")/../.." && pwd)"
build="cargo"
if [ "$use_cross" = "true" ]; then
  build="cross"
fi

cd "$root/native"
"$build" build --release --target "$target" --package typsty_nif \
  --no-default-features --features "nif_version_${nif_version//./_}"
"$build" build --release --target "$target" --package typsty_worker

case "$target" in
  *-pc-windows-*) lib="typsty_nif.dll" prefix="" extension="dll" worker="typsty_worker.exe" ;;
  *-apple-*) lib="libtypsty_nif.dylib" prefix="lib" extension="so" worker="typsty_worker" ;;
  *) lib="libtypsty_nif.so" prefix="lib" extension="so" worker="typsty_worker" ;;
esac

# The name RustlerPrecompiled looks for (macOS NIFs are named .so too)
name="${prefix}typsty_nif-v${version}-nif-${nif_version}-${target}.${extension}"
built="$root/native/target/$target/release"
staging="$root/dist/$target"

rm -rf "$staging"
mkdir -p "$staging"
cp "$built/$lib" "$staging/$name"
cp "$built/$worker" "$staging/$worker"
chmod 755 "$staging/$worker"

# COPYFILE_DISABLE keeps macOS's tar from adding ._ metadata files
tarball="$root/dist/$name.tar.gz"
(cd "$staging" && COPYFILE_DISABLE=1 tar -czf "$tarball" "$name" "$worker")

echo "$tarball"
