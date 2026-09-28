# Sonar

Spotify in your macOS menu bar, with hybrid auto-pause. macOS 15+ only, Spotify-only.

SpotMenu-style UI (artist/title in the menu bar, hover playback controls, like/unlike, next/prev, global shortcuts, compact/full, max-width) plus an Auto-Pause engine that fades + pauses Spotify when another app produces audio and resumes when quiet.

> Status: working dev builds. `brew install --cask sonar` is the target install path (packaging in progress).

## Features

- Identical SpotMenu-style UI: artist/title in menu bar, hover playback controls, like/unlike, next/prev, global shortcuts, compact/full, max-width.
- Auto-Pause: hybrid CoreAudio tap (RMS, clean-room from Apple docs) + `IsRunningOutput` polling. Fade + Pause (2 s out / 2 s in) / Instant / Mute-only, configurable timings.
- Ownership done right: resume-only-if-we-paused (same Spotify pid); any manual pause, volume change, restart, or quit releases ownership and preserves your volume.
- Works with normal Spotify and `headless-spotify` (same `com.spotify.client` + AppleScript, no Premium needed).

## Install

Build from source (Xcode 16+):

```sh
git clone <this-repo> && cd Sonar
xcodebuild -project SpotMenu.xcodeproj -scheme Sonar -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/SpotMenu-*/Build/Products/Release/Sonar.app
```

Release zips + Sparkle updates + Homebrew cask: see TODO tasks 10–12.

## Cutting a release (owner checklist)

1. `git remote add origin <your repo>` + push (remote is `https://github.com/Kathir-D/Sonar.git`).
2. Decide the final bundle ID (currently the `com.you.sonar` placeholder): `SpotMenu.xcodeproj` `PRODUCT_BUNDLE_IDENTIFIER`, `Sonar/Info.plist` URL types, `SpotifyAuthManager` redirect URI + keychain service, `Casks/sonar.rb` zap stanza, `PollDetector` self-exclusion. GitHub URLs already point at `Kathir-D/Sonar`.
3. Sparkle: generate an EdDSA key, put the public key in `SUPublicEDKey`, keep the private key for `sign_update`.
4. Bump `VERSION`, tag `vX.Y.Z`, push (CI builds, tests, packages, publishes the zip).
5. `scripts/sign-release.sh --release` with `DEVELOPER_ID` + `NOTARY_PROFILE`, then re-attach the stapled zip to the GitHub Release.
6. `scripts/generate-appcast.sh <ver> <zip-url>` (signed) → publish `appcast.xml` at the `SUFeedURL` location.
7. `scripts/bump-cask.sh <ver> <sha256>` → copy `Casks/sonar.rb` into your `homebrew-tap` repo → `brew audit --cask --strict sonar` (must pass) → `brew install/test/uninstall --zap` on a fresh user.

## Spotify Setup (liking)

1. developer.spotify.com/dashboard → Create App (name e.g. `Sonar`)
2. Redirect URI: `com.you.sonar://callback`
3. Paste Client ID in Preferences → Music Player

No Premium required for playback control (AppleScript). No Soloist/librespot.

## Permissions

| Permission | Why | If denied |
|---|---|---|
| Audio Capture (`NSAudioCaptureUsageDescription`) | CoreAudio taps (RMS loudness) | poll-only fallback (no RMS, no fade loudness) |
| Automation / AppleEvents for Spotify | pause/play/volume via AppleScript | auto-pause disabled; allow under System Settings › Privacy & Security › Automation |

## How it works

```
Other-app audio (tap RMS) ─┐
                           ├→ Fusion (OR active / AND quiet) → ownership-checked Spotify fade/pause
IsRunningOutput poll ──────┘
```

- Either detector loud for ≥ Active duration (default 1 s) → duck Spotify.
- Both quiet for ≥ Quiet duration (default 3 s) **and** Spotify still paused by us → resume.
- Manual pause/volume/player-restart relinquishes ownership; stopped Spotify is never started.

Diagnostics live in Preferences → Auto-Pause: state dot, poll/tap state, live RMS, duck/resume countdowns, last result, recent-sources finder, and the log path.

Log: `~/Library/Containers/com.you.sonar/Data/Library/Logs/Sonar/sonar.log` (sandboxed dev builds; capped at 256 KB).

## Building

```sh
swift test --package-path Packages/AutoPauseEngine   # engine: 39 tests
xcodebuild -project SpotMenu.xcodeproj -scheme Sonar -configuration Debug build
```

## Credits & Provenance

| What | Source | Author | License | Upstream SHA | How used |
|---|---|---|---|---|---|
| Menu UI, prefs, Spotify controller | https://github.com/kmikiy/SpotMenu | @kmikiy | MIT 2016 | `a1148193` | Fork base, Spotify-only strip, UI identical |
| Poll detector, ownership lessons | https://github.com/yasinozmeen/smartpause | @yasinozmeen | MIT 2026 | `69f3a9d` | Verbatim port with headers kept |
| Tap/ducking concepts | https://github.com/mattwong05/FlowSound | @mattwong05 | NO LICENSE — ideas only | n/a | Reimplemented from Apple docs, no verbatim copy |
| CoreAudio API | Apple Developer docs | Apple | — | — | Clean-room impl |

Full texts: see `THIRD-PARTY-NOTICES.md` + `LICENSE`.

## License

MIT — see `LICENSE`.
