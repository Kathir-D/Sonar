#!/bin/sh
# Fill a version and checksum into Casks/sonar.rb. The release workflow does the
# same on every tag and commits the result to Kathir-D/homebrew-tap; this is the
# by-hand fallback. It edits the two lines in place rather than regenerating the
# file, so the rest of the cask (postflight, zap, comments) stays as committed.
# Usage: scripts/bump-cask.sh <version> <sha256>
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: bump-cask.sh <version> <sha256>}"
SHA="${2:?usage: bump-cask.sh <version> <sha256>}"
CASK="$ROOT/Casks/sonar.rb"

sed -i.bak \
  -e "s/^  version \".*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  "$CASK"
rm -f "$CASK.bak"
echo "Wrote $CASK ($VERSION)"
