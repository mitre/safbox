#!/usr/bin/env bash
# Install the bats test runner and its helper libraries at pinned releases:
# download each release tarball from GitHub, check it against the sha256
# below, and unpack it into .build/bats/<name>/ (git-ignored). A library
# already unpacked at its pinned version and checksum is left alone, so
# tests/bats/run.sh calls this every time. A checksum mismatch stops the
# install with nothing unpacked; update a pin only together with its
# checksum, after reviewing the release.
#
#   tests/bats/install.sh
#   SAFBOX_BATS_DIR=/path tests/bats/install.sh    install somewhere else
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEST=${SAFBOX_BATS_DIR:-$ROOT/.build/bats}

# name, release, sha256 of github.com/bats-core/<name>/archive/refs/tags/v<release>.tar.gz
PINS=(
  "bats-core    1.14.0 bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177"
  "bats-support 0.3.0  7815237aafeb42ddcc1b8c698fc5808026d33317d8701d5ec2396e9634e2918f"
  "bats-assert  2.2.4  e305df20c4c36cba4570e10f1cd824efb1ae71d88b5ef474550781ebee04192f"
  "bats-file    0.4.0  9b69043241f3af1c2d251f89b4fcafa5df3f05e97b89db18d7c9bdf5731bb27a"
)

# sha256 of a file: sha256sum (GNU coreutils) or shasum (macOS).
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$DEST"
work=$(mktemp -d "$DEST/.fetch.XXXXXX")
trap 'rm -rf "$work"' EXIT

for pin in "${PINS[@]}"; do
  read -r name release want <<<"$pin"
  stamp="$name $release $want"
  if [ "$(cat "$DEST/$name/.pin" 2>/dev/null)" = "$stamp" ]; then continue; fi
  url="https://github.com/bats-core/$name/archive/refs/tags/v$release.tar.gz"
  echo "fetching $name $release"
  curl -fsSL --retry 3 -o "$work/$name.tar.gz" "$url"
  got=$(sha256 "$work/$name.tar.gz")
  if [ "$got" != "$want" ]; then
    echo "FAIL: $url has sha256 $got, pinned $want" >&2
    exit 1
  fi
  mkdir "$work/$name"
  tar -xzf "$work/$name.tar.gz" -C "$work/$name" --strip-components=1
  echo "$stamp" > "$work/$name/.pin"
  rm -rf "${DEST:?}/$name"
  mv "$work/$name" "$DEST/$name"
done
