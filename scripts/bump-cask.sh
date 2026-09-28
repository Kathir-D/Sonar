#!/bin/sh
# Fill Casks/sonar.rb from a built release.
# Usage: scripts/bump-cask.sh <version> <sha256> <zip-url>
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: bump-cask.sh <version> <sha256> <zip-url>}"
SHA="${2:?usage: bump-cask.sh <version> <sha256> <zip-url>}"
URL="${3:?usage: bump-cask.sh <version> <sha256> <zip-url>}"

cat > "$ROOT/Casks/sonar.rb" <<EOF
cask "sonar" do
  version "$VERSION"
  sha256 "$SHA"

  url "$URL"
  name "Sonar"
  desc "Spotify in your macOS menu bar, with hybrid auto-pause"
  homepage "https://github.com/you/sonar"

  depends_on macos: ">= :sequoia"
  conflicts_with cask: "spotmenu"

  app "Sonar.app"

  zap trash: [
    "~/Library/Caches/com.you.sonar",
    "~/Library/Containers/com.you.sonar",
    "~/Library/Logs/Sonar",
    "~/Library/Preferences/com.you.sonar.plist",
  ]
end
EOF
echo "Wrote $ROOT/Casks/sonar.rb ($VERSION)"
