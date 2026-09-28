cask "sonar" do
  version "0.1.0"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/you/sonar/releases/download/v#{version}/Sonar-#{version}.zip"
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
