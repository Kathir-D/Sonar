# Sonar

Spotify in your macOS menu bar, with hybrid auto-pause. macOS 15+ only, Spotify-only.

> Status: scaffold. Fork import of SpotMenu UI lands next (`chore: import SpotMenu`).

## Features (target)

- Identical SpotMenu-style UI: artist/title in menu bar, hover playback controls, like/unlike, next/prev, global shortcuts, compact/full, max-width.
- Auto-Pause: hybrid CoreAudio tap (RMS, from Apple docs) + `IsRunningOutput` polling. Fade + Pause / Instant / Mute-only, configurable timings.
- Works with normal Spotify and `headless-spotify` (same `com.spotify.client` + AppleScript, no Premium needed).

## Install

TBD — zip + `open Sonar.xcodeproj` (Xcode 15+). See `docs/` once imported.

## Spotify Setup (liking)

1. developer.spotify.com/dashboard → Create App
2. Redirect URI: `com.you.sonar://callback` (update `SpotifyAuthManager` accordingly)
3. Paste Client ID in Preferences → Music Player

No Premium required for playback control (AppleScript). No Soloist/librespot.

## Permissions

| Permission | Why | If denied |
|---|---|---|
| Audio Capture (`NSAudioCaptureUsageDescription`) | CoreAudio taps | poll-only fallback |
| Automation / AppleEvents for Spotify | pause/play/volume | feature disabled with hint |

## How it works

```
Other-app audio (tap RMS) ─┐
                           ├→ Fusion (OR active / AND quiet) + isPlaying() veto → StateMachine → Spotify fade/pause
IsRunningOutput poll ──────┘
```

Resume-only-if-we-paused. Manual pause/volume/player-restart relinquishes ownership.

## Building

```sh
swift test            # AutoPauseEngine package (once added)
xcodebuild -project Sonar.xcodeproj -scheme Sonar build
```

## Credits & Provenance

| What | Source | Author | License | Upstream SHA | How used |
|---|---|---|---|---|---|
| Menu UI, prefs, Spotify controller | https://github.com/kmikiy/SpotMenu | @kmikiy | MIT 2016 | TBD at import | Fork base, Spotify-only strip, UI identical |
| Poll detector, ownership lessons | https://github.com/yasinozmeen/smartpause | @yasinozmeen | MIT 2026 | TBD | Verbatim port with headers kept |
| Tap/ducking concepts | https://github.com/mattwong05/FlowSound | @mattwong05 | NO LICENSE — ideas only | n/a | Reimplemented from Apple docs, no verbatim copy |
| CoreAudio API | Apple Developer docs | Apple | — | — | Clean-room impl |

Full texts: see `THIRD-PARTY-NOTICES.md` + `LICENSE`.

## License

MIT — see `LICENSE`.
