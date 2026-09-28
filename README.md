# Sonar

[![CI](https://github.com/Kathir-D/Sonar/actions/workflows/ci.yml/badge.svg)](https://github.com/Kathir-D/Sonar/actions/workflows/ci.yml)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)](https://support.apple.com/macos)
[![Spotify](https://img.shields.io/badge/Spotify-only-1DB954?logo=spotify&logoColor=white)](https://open.spotify.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> Spotify in your macOS menu bar, with hybrid auto-pause.

Sonar shows the current artist/title in the menu bar with hover playback controls (play/pause, next/previous, like/unlike, global shortcuts, compact/full layouts) and fades + pauses Spotify automatically when another app produces audio — then resumes when it's quiet.

<!-- Demo GIF wanted: menu-bar + YouTube duck/resume. See TODO task 9. -->

## Contents

- [Features](#features)
- [Install](#install)
- [Spotify Setup](#spotify-setup)
- [Usage](#usage)
- [How It Works](#how-it-works)
- [Permissions](#permissions)
- [Building](#building)
- [Cutting a Release](#cutting-a-release)
- [Credits & Provenance](#credits--provenance)
- [License](#license)

## Features

- **SpotMenu-style UI** — artist/title in the menu bar, hover playback controls, like/unlike, next/prev, global shortcuts, compact/full, max-width.
- **Hybrid auto-pause** — CoreAudio tap (RMS loudness) fused with `IsRunningOutput` polling. Fade + Pause (2 s out / 2 s in), Instant, or Mute-only, with configurable timings.
- **Ownership done right** — resumes only if Sonar paused Spotify (same pid); any manual pause, volume change, player restart, or quit releases ownership and preserves your volume.
- **No Premium needed** — playback control via AppleScript. Works with normal Spotify and `headless-spotify` (same `com.spotify.client`).

## Install

**Homebrew (target path):**

```sh
brew install --cask sonar
```

Packaging is in progress — until the first release, build from source (Xcode 16+):

```sh
git clone https://github.com/Kathir-D/Sonar.git && cd Sonar
xcodebuild -project SpotMenu.xcodeproj -scheme Sonar -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/SpotMenu-*/Build/Products/Release/Sonar.app
```

## Spotify Setup

Liking tracks needs a free Spotify app registration (playback control itself does not):

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) → Create App (name e.g. `Sonar`).
2. Add this Redirect URI:
   `com.kathird.sonar://callback` (all lowercase — OAuth schemes are case-sensitive on the wire).
3. Paste the Client ID into Sonar's Preferences → Music Player and log in.

## Usage

- Click the menu-bar track to reveal controls; hover for playback buttons.
- Preferences → Auto-Pause: mode (Fade+Pause / Instant / Mute-only), active/quiet durations, loudness threshold, all-except vs. watched-only app lists.
- Preferences → Auto-Pause (diagnostics): state dot, poll/tap state, live RMS, duck/resume countdowns, last result, recent-sources finder, log path.
- Log: `~/Library/Containers/com.KathirD.sonar/Data/Library/Logs/Sonar/sonar.log` (sandboxed dev builds; capped at 256 KB).

## How It Works

```
Other-app audio (tap RMS) ─┐
                           ├→ Fusion (OR active / AND quiet) → ownership-checked Spotify fade/pause
IsRunningOutput poll ──────┘
```

- Either detector loud for ≥ Active duration (default 1 s) → duck Spotify.
- Both quiet for ≥ Quiet duration (default 3 s) **and** Spotify still paused by us → resume.
- Manual pause/volume/player-restart relinquishes ownership; stopped Spotify is never started.

## Permissions

| Permission | Why | If denied |
|---|---|---|
| Audio Capture (`NSAudioCaptureUsageDescription`) | CoreAudio taps (RMS loudness) | poll-only fallback (no RMS, no fade loudness) |
| Automation / AppleEvents for Spotify | pause/play/volume via AppleScript | auto-pause disabled; allow under System Settings › Privacy & Security › Automation |

## Building

Requirements: Xcode 16+, macOS 15 SDK, Swift 6.

```sh
swift test --package-path Packages/AutoPauseEngine   # engine: 39 tests
xcodebuild -project SpotMenu.xcodeproj -scheme Sonar -configuration Debug build
```

Project layout: `Sonar/` (menu-bar UI, Xcode project) + `Packages/AutoPauseEngine` (testable detection/fusion/fade SPM library). See `TODO.md` for the build history and `THIRD-PARTY-NOTICES.md` for provenance.

## Cutting a Release

<details>
<summary>Owner checklist (click to expand)</summary>

1. Push to `main` (remote is `https://github.com/Kathir-D/Sonar.git`).
2. Bundle ID is `com.KathirD.sonar`; OAuth redirect URI is lowercase `com.kathird.sonar://callback`.
3. Sparkle: `SUPublicEDKey` is wired; keep the private key in the login Keychain for `sign_update` (never commit it).
4. Bump `VERSION`, tag `vX.Y.Z`, push (CI builds, tests, packages, publishes the zip).
5. `scripts/sign-release.sh --release` with `DEVELOPER_ID` + `NOTARY_PROFILE`, then re-attach the stapled zip to the GitHub Release.
6. `scripts/generate-appcast.sh <ver> <zip-url>` (signed) → publish `appcast.xml` at the `SUFeedURL` location.
7. `scripts/bump-cask.sh <ver> <sha256>` → copy `Casks/sonar.rb` into your `homebrew-tap` repo → `brew audit --cask --strict sonar` (must pass) → `brew install/test/uninstall --zap` on a fresh user.

</details>

## Credits & Provenance

| What | Source | Author | License | Upstream SHA | How used |
|---|---|---|---|---|---|
| Menu UI, prefs, Spotify controller | https://github.com/kmikiy/SpotMenu | @kmikiy | MIT 2016 | `a1148193` | Fork base, Spotify-only strip, UI identical |
| Poll detector, ownership lessons | https://github.com/yasinozmeen/smartpause | @yasinozmeen | MIT 2026 | `69f3a9d` | Verbatim port with headers kept |
| Tap/ducking concepts | https://github.com/mattwong05/FlowSound | @mattwong05 | NO LICENSE — ideas only | n/a | Reimplemented from Apple docs, no verbatim copy |
| CoreAudio API | Apple Developer docs | Apple | — | — | Clean-room impl |

Full texts: see `THIRD-PARTY-NOTICES.md` + `LICENSE`.

## License

MIT — see [LICENSE](LICENSE).
