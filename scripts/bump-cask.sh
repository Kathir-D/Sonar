#!/bin/sh
# Fill Casks/sonar.rb from a built release.
# Usage: scripts/bump-cask.sh <version> <sha256>
# (URL is derived from the version by Homebrew interpolation.)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: bump-cask.sh <version> <sha256>}"
SHA="${2:?usage: bump-cask.sh <version> <sha256>}"

cat > "$ROOT/Casks/sonar.rb" <<EOF
cask "sonar" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/Kathir-D/Sonar/releases/download/v#{version}/Sonar-#{version}.zip"
  name "Sonar"
  desc "Spotify in your macOS menu bar, with hybrid auto-pause"
  homepage "https://github.com/Kathir-D/Sonar"

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
