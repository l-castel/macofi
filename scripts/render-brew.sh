#!/bin/bash
# Usage: render-brew.sh VERSION OWNER/REPO DIST_DIR [BASE_URL]
# Writes Formula/macofi.rb and Casks/macofi.rb (the repo doubles as a Homebrew tap).
# BASE_URL defaults to the GitHub release for vVERSION; pass file://… to test locally.
set -euo pipefail
version=$1 repo=$2 dist=$3
base=${4:-https://github.com/$repo/releases/download/v$version}
# Casks must interpolate the version in their URL (brew audit), so use #{version} there.
dmg_base=${4:-"https://github.com/$repo/releases/download/v#{version}"}
root=$(cd "$(dirname "$0")/.." && pwd)
src="$dist/macofi-$version-src.tar.gz" dmg="$dist/Macofi-$version.dmg"
for f in "$src" "$dmg"; do [ -f "$f" ] || { echo "missing $f (run make dist)" >&2; exit 1; }; done

render() {
  sed -e "s|@VERSION@|$version|g" -e "s|@REPO@|$repo|g" \
      -e "s|@SRC_URL@|$base/macofi-$version-src.tar.gz|g" \
      -e "s|@SRC_SHA256@|$(shasum -a 256 "$src" | cut -d' ' -f1)|g" \
      -e "s|@DMG_BASE@|$dmg_base|g" \
      -e "s|@DMG_SHA256@|$(shasum -a 256 "$dmg" | cut -d' ' -f1)|g" \
      "$1" > "$2"
}
mkdir -p "$root/Formula" "$root/Casks"
render "$root/packaging/macofi.rb.in" "$root/Formula/macofi.rb"
render "$root/packaging/macofi-cask.rb.in" "$root/Casks/macofi.rb"
echo "wrote Formula/macofi.rb and Casks/macofi.rb for v$version ($base)"
