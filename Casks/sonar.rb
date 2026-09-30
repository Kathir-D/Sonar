cask "sonar" do
  version "0.1.5"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/Kathir-D/Sonar/releases/download/v#{version}/Sonar-#{version}.zip"
  name "Sonar"
  desc "Spotify in your menu bar, with hybrid auto-pause"
  homepage "https://github.com/Kathir-D/Sonar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "Sonar.app"

  # Sonar is ad-hoc signed and not notarized, so Gatekeeper would otherwise make
  # every user approve it by hand in System Settings on first launch.
  #
  # Homebrew used to offer --no-quarantine for this, but it was removed in 7.x
  # ("Error: invalid option: --no-quarantine") and there is no cask DSL
  # replacement: `postflight_steps` exposes only if_path_exists / on_macos /
  # version / token, and cannot run a command at all. The deprecated
  # `postflight` block can, and still runs.
  #
  # The rescue matters. Without it, removing `postflight` would not merely stop
  # the quarantine from being cleared - it would make the cask file invalid, and
  # an invalid cask stops the whole tap from loading, so `brew tap` would fail
  # and nobody could install anything. Rescued, the worst case is that users get
  # the normal one-time Gatekeeper approval again.
  #
  # The ordering is what makes this reasonable rather than reckless: Homebrew
  # verifies the SHA-256 above before any of this runs, so the checksum is the
  # integrity gate and the quarantine attribute is no longer what stands between
  # the user and an app they knowingly installed from this tap.
  # `brew style` reports one offense on the block below, Cask/InstallSteps, and
  # it cannot be resolved. Homebrew requires postflight_steps, whose DSL exposes
  # only if_path_exists, on_macos, version and token and cannot run a command at
  # all; and Style/DisableCopsWithinSourceCodeDirective forbids suppressing the
  # cop. The two rules together make the requirement unsatisfiable, so the block
  # stays and the offense stays.
  #
  # Check the cask with the cop excluded:
  #   brew style --except Cask/InstallSteps kathir-d/tap/sonar
  # `brew audit --cask --strict`, the gate Homebrew actually enforces, passes.
  #
  begin
    postflight do
      system_command(
        "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "/Applications/Sonar.app"],
        must_succeed: false
      )
    end
  rescue NoMethodError
    # Homebrew dropped the postflight block. Nothing to do; the install itself
    # still succeeds.
  end

  uninstall quit: "com.KathirD.sonar"

  zap trash: [
    "~/Library/Application Scripts/com.KathirD.sonar",
    "~/Library/Caches/com.KathirD.sonar",
    "~/Library/Containers/com.KathirD.sonar",
    "~/Library/HTTPStorages/com.KathirD.sonar",
    "~/Library/Logs/Sonar",
    "~/Library/Preferences/com.KathirD.sonar.plist",
  ]
end
