# Sonar — Implementation TODO

> macOS 15+ menu-bar Spotify viewer + hybrid auto-pause. Spotify-only. Full SpotMenu UI preserved, features added on top.

## 0. Context / why this exists

- Fork base is `kmikiy/SpotMenu` (MIT 2016). Users love its menu-bar UI + customizability (artist/title, hover controls, like/unlike, shortcuts, compact/full, max-width). Keep it pixel-identical.
- Add FlowSound-style auto-pause (fade + pause/resume) + SmartPause-style lightweight detection, fused for accuracy.
- Must work with both normal Spotify and `../headless-spotify` (same `com.spotify.client`, same AppleScript — no code fork).
- No Premium required. No Soloist/librespot (Linux-only + Premium-gated — rejected).

## 1. Hard rules (do not violate)

1. **Licenses:** SpotMenu MIT + SmartPause MIT = OK to copy with headers + SHA recorded in `THIRD-PARTY-NOTICES.md`. FlowSound has NO LICENSE = ideas-only, NEVER vendor files; reimplement taps from Apple docs (`capturing-system-audio-with-core-audio-taps`, `CATapDescription`).
2. **UI freeze:** `StatusItem/`, `PlaybackView/SliderView/PlaybackModel`, `Preferences` existing panes, `SpotifyAuthManager/LoginView` stay identical except Spotify-only enforcement + new `Auto-Pause` pane.
3. **Spotify contract:** match only `bundleID == com.spotify.client` + `tell application "Spotify" to get player state`. Never match Dock/window. Explicit `play`/`pause` (never `playpause` toggle). All AppleScript off-main serial queue, `with timeout of 4 seconds`, 200 ms re-read after command.
4. **Ownership:** resume-only-if-we-paused same pid; manual pause/volume/restart/Quit relinquishes; generation tokens; preserve restore volume on interrupt.
5. **Build:** Hybrid — `Sonar.xcodeproj` (UI) + `Packages/AutoPauseEngine` SPM lib (macOS 15). `swift test` must pass. Never commit secrets (Client ID), certs, `.build/`, `DerivedData/`.
6. **Commits:** conventional (`chore:/feat:/fix:/docs:`), small, `git status` first. Record upstream SHAs in commit bodies + NOTICES.

## 2. Task list (in order)

### [x] 1. `chore: import SpotMenu @SHA`
- Why: verbatim UI baseline before any change.
- Do: clone `kmikiy/SpotMenu`, copy `SpotMenu/`, `SpotMenu.xcodeproj`, `Sparkle/`, upstream `LICENSE` history; record SHA in `THIRD-PARTY-NOTICES.md`; `xcodebuild build` must succeed unmodified.
- Done when: clean build, menu bar shows, git log shows SHA ref.

### [x] 2. `chore: add AutoPauseEngine SPM skeleton`
- Why: isolate new engine for testability + parallel work.
- Do: `Packages/AutoPauseEngine/Package.swift` (macOS 15 lib, Swift 6), empty `HybridDetector`, `FusionState`, `SpotifyFadeAdapter`; link as local package in Xcode; `swift test` green.
- Done when: Xcode builds + `swift test` passes.

### [x] 3. `feat!: rename to Sonar`
- Why: new brand, avoid collision.
- Do: bundle ID `com.KathirD.sonar`, `com.KathirD.sonar://callback`, display name Sonar, Info.plist `NSAudioCaptureUsageDescription`.
- Done when: app installs side-by-side with SpotMenu, liking callback uses new URI (update Spotify Dashboard).

### [x] 4. `feat: enforce Spotify-only`
- Why: scope is Spotify; remove Apple Music branches but keep UI.
- Do: delete/gate `AppleMusicController.swift` + picker → force `.spotify`; keep like/unlike, next/prev, shortcuts, compact/full.
- Done when: no Apple Music refs in prefs, all Spotify controls work.

### [x] 5. `feat: poll detector (SmartPause MIT)`
- Why: no-permission fallback, 0 idle CPU.
- Do: port `AudioDetector.swift` + `AudioActivityTracker.swift` (keep MIT headers), `kAudioHardwarePropertyProcessObjectList` + `IsRunningOutput`, helper→parent via `responsibility_get_pid_responsible_for_pid`, Safari/WebKit expansion, exclusions (self, Spotify, `systemsoundserverd`, `usernoted`).
- Done when: unit tests for helper mapping + exclusions; manual YouTube detection without audio permission.

### [x] 6. `feat: tap detector (clean-room)`
- Why: RMS accuracy + fade support; needs Audio Capture permission.
- Do: NEW code from Apple docs only — bundle-ID exclusive tap, private aggregate + IO proc, RMS, 1 s active / 0.75 s gap / 3 s quiet / 0.1 s quiet-check; rebuild on device/sleep/wake; degraded to poll-only if denied.
- Done when: tap active shows RMS, denial banner shows poll-only mode, no FlowSound code copied.

### [x] 7. `feat: fusion + fade adapter`
- Why: combine both signals per user decision (OR-active / AND-quiet).
- Do: `Fusion: either loud ≥ activeDuration → candidate; both quiet ≥ quietDuration + isPlaying()==false → resume`. Modes: Fade+Pause (2 s/pause/3 s/2 s defaults) / Instant / Mute-only. `SpotifyFadeAdapter`: volume capture, fade via `set sound volume`, bounded serialized runner.
- Done when: state-machine tests green; manual Spotify fades on YouTube, resumes after 3 s quiet, no resume after manual pause.

### [x] 8. `feat: Auto-Pause prefs + diagnostics`
- Why: configurability without touching existing panes.
- Do: new pane (mode radio, sliders + numeric for active/quiet/fade/threshold, all-except vs watched-only lists, recent-sources 3-min finder, menu-dot state, diagnostics countdown + last-result + permission hints, bounded `~/Library/Logs/Sonar/` log).
- Done when: prefs persist in UserDefaults, Save restarts tap only when rules change.

### [x] 9. `docs: README + NOTICES final`
- Why: fresh rewrite + provenance required.
- Do: fill demo gif, install, permissions table, usage, building, Credits table with final SHAs.
- Done when: README matches implementation, NOTICES has full MIT texts.

## 3. Test matrix (run before done)

- Safari/Chrome YouTube (all-except + watched-only), Telegram pings, Zoom/Discord, Spotify restart mid-duck, tap-denied fallback, fresh-user permission flow, sleep/wake + device switch.

## 4. Key files

- `SpotMenu/StatusItem/*`, `SpotMenu/Playback/SpotifyController.swift`, `Packages/AutoPauseEngine/*`, `THIRD-PARTY-NOTICES.md`

## 5. Homebrew + prod (cask)

Why: `brew install --cask sonar` is the target install path.

### [x] 10. `feat: release packaging (zip + checksums + Homebrew cask)`
- Do: `scripts/build-app.sh` (build Release, inject `VERSION` into Info.plist), `scripts/package-release.sh` → `dist/<ver>/Sonar-<ver>.zip` + `SHA256SUMS.txt`; keep `Casks/sonar.rb` in sync with the release.
- Done when: clean VM can unzip + run, About shows VERSION, `brew install --cask` works.

  *Revised after the 0.1.0 decision to drop the in-app updater: releases ship as a signed,
  notarized zip and a cask, and `brew upgrade --cask sonar` is the update path.*

### [x] 11. `feat: signing + notarization`
- Why: Gatekeeper + Homebrew cask warnings otherwise (`Open Anyway` fallback for ad-hoc dev only).
- Do: Hardened Runtime + entitlements (Audio Capture usage string, AppleEvents for `com.spotify.client`), Developer ID sign + `notarytool` staple in release lane; keep ad-hoc lane for local dev.
- Done when: `spctl -a -vv` + `stapler validate` pass on release zip.

### [x] 12. `feat: homebrew-tap cask`
- Do: create 3rd repo `homebrew-tap` (`Casks/sonar.rb`: version, sha256, url to GitHub Release zip, `app "Sonar.app"`, `zap` stanza for prefs/logs, `depends_on macos: ">= :sequoia"`, `conflicts_with cask: "spotmenu"`); `brew audit --cask --strict`, `brew install --cask`, `brew test`, `brew uninstall --cask --zap` on fresh user; CI job bumps version+sha on every GitHub Release.
- Done when: `brew tap you/tap && brew install --cask sonar` works from scratch, zap cleans fully.
