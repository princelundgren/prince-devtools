#!/usr/bin/env bash
# Usage: make-dmg.sh <app> <version> <out-dir>
# Writes <out-dir>/PrinceDevTools-<version>.dmg, holding the app and an /Applications link, and
# prints its path.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <app> <version> <out-dir>" >&2
  exit 64
fi
app="$1"
version="$2"
out_dir="$3"

if [[ ! -d "$app" ]]; then
  echo "make-dmg: no app bundle at $app" >&2
  exit 1
fi

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

# ditto keeps the framework symlinks and the signatures that depend on them.
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"
# mktemp's folder is private, and it becomes the volume's root.
chmod 755 "$staging"

mkdir -p "$out_dir"
dmg="$out_dir/PrinceDevTools-$version.dmg"
# APFS with LZFSE compression, as Sparkle recommends for a DMG it updates from.
hdiutil create -quiet -volname "PrinceDevTools $version" -srcfolder "$staging" \
  -fs APFS -format ULFO -ov "$dmg"
echo "$dmg"
