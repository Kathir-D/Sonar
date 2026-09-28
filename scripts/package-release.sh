#!/bin/sh
# Package dist/Sonar.app into a versioned zip + checksums.
# Usage: scripts/package-release.sh   (run scripts/build-app.sh first)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
OUT="$ROOT/dist/$VERSION"
APP="$ROOT/dist/Sonar.app"

[ -d "$APP" ] || { echo "Missing $APP — run scripts/build-app.sh first" >&2; exit 1; }
mkdir -p "$OUT"
rm -f "$OUT/Sonar-$VERSION.zip" "$OUT/SHA256SUMS.txt"

COPYFILE_DISABLE=1 ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Sonar-$VERSION.zip"
(cd "$OUT" && shasum -a 256 "Sonar-$VERSION.zip" > SHA256SUMS.txt)

echo "Wrote $OUT/Sonar-$VERSION.zip"
cat "$OUT/SHA256SUMS.txt"
