# Auto-Pause end-to-end test + README corrections — agent-e2e

**Read this if** you own `Sonar/Preferences/*`, `Sonar/Engine/SonarPermissions.swift`,
`Sonar/Info.plist`, or you are the agent designated to run audio on this machine.
There are **two required patches that are not mine to apply** (§6) and **one
environment blocker that will stop the test before it starts** (§5).

- **Author:** agent-e2e
- **Date:** 2026-09-28, 21:45 CDT
- **Git HEAD when written:** `2e6bf0a` ("docs: add parallel-work contract")
- **Files I changed (my ownership only):** `scripts/autopause-smoke.sh` (new),
  `README.md`. Nothing under `Sonar/**` or `Packages/**`, nothing staged, nothing
  committed.
- **Related:** [`AUTOPAUSE-ENGINE-AUDIT.md`](AUTOPAUSE-ENGINE-AUDIT.md) — the
  engine's internals. This document is the other half: the black-box check that
  the assembled feature works, plus the user-facing documentation it needs.

## Snapshot this report is pinned to

The app and engine were being actively rewritten while I verified against them.
Everything below was re-read from the working copy at these SHA-1s, not from HEAD:

| SHA-1 (first 12) | mtime | File |
|---|---|---|
| `0139760af22a` | 21:16 | `Sonar/Preferences/AutoPausePreferencesModel.swift` |
| `dc9448dd89c7` | 21:05 | `Packages/AutoPauseEngine/Sources/AutoPauseEngine/AutoPausePreset.swift` |
| `4482d23f5112` | 21:16 | `Sonar/Preferences/AutoPausePreferencesView.swift` |
| `74560e854b8b` | 20:50 | `Sonar/Engine/SonarPermissions.swift` |
| `760e611bbdec` | 21:14 | `Sonar/Engine/SonarLog.swift` |
| `5614310068dc` | 21:40 | `Sonar/Engine/SonarEngineHost.swift` |
| `372efd994dd6` | 17:20 | `Sonar/Playback/PlaybackModel.swift` |
| `3a0164ffe2ba` | 17:01 | `Sonar/Playback/SpotifyController.swift` |
| `b94faffda217` | 02:26 | `Sonar/Info.plist` |

If a line number below does not match your working copy, the file is newer than
this report — re-derive the line, not the conclusion. The one thing I checked
repeatedly because it moved: `AutoPausePreferencesModel.Key` and
`AutoPausePreset.instant` were **stable** across the whole session.

---

## 1. What I built: `scripts/autopause-smoke.sh`

One command that answers "does Auto-Pause actually pause Spotify when another app
makes sound, and resume it when that sound stops, on the INSTANT preset?".
`sh`-compatible, `set -eu`, coloured PASS/FAIL, non-zero exit on failure, and a
summary table of every assertion with measured latency in milliseconds.

```
$ sh scripts/autopause-smoke.sh            # test the installed app
$ sh scripts/autopause-smoke.sh --dry-run  # print every command, touch nothing
$ sh scripts/autopause-smoke.sh --help     # options + env reference
```

Steps, each individually skippable and each announcing what it did:

1. **Build** — `env DEVELOPER_DIR=… xcodebuild -project SpotMenu.xcodeproj -scheme Sonar
   -configuration Release -derivedDataPath <own path> … build`. `DEVELOPER_DIR` is
   mandatory here (`xcode-select -p` → `/Library/Developer/CommandLineTools`).
   **Off unless `--build`.**
2. **Install** — stages to `dist/autopause-smoke/stage/Sonar.app` and requires
   `codesign -v` to pass, then (loudly, after saying it will quit the running
   app) replaces `$SONAR_APP`. **Off unless `--install`; `/Applications` is never
   touched otherwise.**
3. **Spotify** — reports `player state` and `sound volume`. Launches Spotify if it
   is not running (`--no-launch-spotify` to refuse), but **never starts playback
   without `--allow-playback`**.
4. **Force Instant** — quits Sonar, writes the `autopause.*` keys, reads them all
   back and asserts them, launches Sonar, then waits for `engine started` and for
   the tap verdict (`tap verified:` / `tap unavailable:`) in the log.
5. **Tone** — a 1 kHz sine WAV written by `python3` from the standard library only,
   played by `afplay` for a fixed duration.
6. **Assert** — polls `player state`, records monotonic timestamps, and reports
   pause latency (tone start → paused) and resume latency (tone stop → playing)
   against `--pause-threshold-ms` (2000) and `--resume-threshold-ms` (3000). Also
   prints the engine's log lines from this run and names which detector drove the
   decision.
7. **Clean up** — always, via an `EXIT`/`INT`/`TERM` trap: stops `afplay`, puts
   Spotify back to the play/pause state and volume it found, restores the previous
   `autopause.*` plist byte for byte, and reports anything it could not restore.

Env: `SONAR_APP`, `SONAR_BUNDLE_ID`, `SONAR_PREFS_DOMAIN`, `SPOTIFY_BUNDLE`,
`TONE_WAV`, `PRESET_THRESHOLD`, `DEVELOPER_DIR`, `CODE_SIGN_IDENTITY`.

### Measurement honesty

`player state` is polled over AppleScript, so each sample costs a round trip. The
script reports an **upper bound** and prints the **sampling quantum** beside every
number (`playing->paused, sampled every 152 ms`) rather than implying a precision
it does not have. `time.monotonic()` is used because every poll is a separate
process and the clock has to be machine-wide.

## 2. What I verified without touching audio

| Check | Result |
|---|---|
| `sh -n scripts/autopause-smoke.sh` | OK |
| `--help` | exit 0 |
| `--dry-run`, and `--dry-run --build --install` | exit 0, 25 commands printed, nothing executed |
| Unknown option, and `VAR=x` passed as an argument | named error + hint that env must precede the script name |
| `SONAR_APP=/nonexistent` | clear message, `FAIL app-present`, summary, exit 1, no side effects |
| Prefs write → read-back → assert, against a temp plist | all nine keys verified, incl. float tolerance |
| Prefs restore (whole-file `cp`) | a pre-seeded plist with `-float`, `-bool`, `-string` and a one-item `-array` came back **byte-identical in type and content** |
| Tone generation | 6.000 s, 1 ch, 44 100 Hz, Int16, `afinfo` parses it, **RMS 0.3535** vs the 0.02 engine floor |
| Cleanup | runs on every exit path; an already-running process named `Sonar` is left alone (fake-process test) |
| `shellcheck` | **not installed on this host** — not run |

I did not run the full audio test, install into `/Applications/Sonar.app`, launch
or quit Spotify, control Chrome audio, or reset any TCC permission.

## 3. The UserDefaults contract, verified against the source

`AutoPausePreferencesModel.Key` (lines 24–34) and `AutoPausePreset.instant`
(lines 36–68) — both re-read at the SHA-1s above:

| Key the script writes | Value | Where the value comes from |
|---|---|---|
| `autopause.enabled` | `-bool true` | model:73 (`?? true`) |
| `autopause.mode` | `-string instant` | `case .instant: return .instant`; `DuckMode.instant` rawValue is `"instant"` |
| `autopause.activeDuration` | `-float 0.1` | `case .instant: return 0.1` |
| `autopause.quietDuration` | `-float 0.3` | `case .instant: return 0.3` |
| `autopause.fadeOut` | `-float 0.0` | `case .instant: return 0.0` |
| `autopause.fadeIn` | `-float 0.0` | `case .instant: return 0.0` |
| `autopause.threshold` | `-float 0.02` | `presetThreshold` → `AutoPausePreset.fade.threshold` |
| `autopause.filterMode` | `-string allExcept` | `case allExcept = "allExcept"` |
| `autopause.bundleIDs` | `-array` (empty) | model:96 (`?? []`) |

**The app is sandboxed, so these go to the container plist, not the bare domain:**
`~/Library/Containers/com.KathirD.sonar/Data/Library/Preferences/com.KathirD.sonar.plist`.
Writing `com.KathirD.sonar` would create a *different* file that the app never
reads — a silent no-op that looks like a passing test. `SONAR_PREFS_DOMAIN`
overrides the target; a bare domain is supported for an unsandboxed build.

## 4. The README corrections

Sections that were factually wrong, with the reason each was wrong:

| Section | Was | Now |
|---|---|---|
| Why two detectors? | "The poll keeps auto-pause working before you grant the permission, after you deny it"; tap row said a denied permission "turns it off entirely" | The poll is a safety net for what the tap cannot attach to, but **not a substitute for the permission** — Auto-Pause will not switch on without both grants |
| Requirements | "Automation (Apple Events) for Spotify; Audio Capture (optional)" | Both permissions, and the feature stays off without them |
| Features › Auto-pause | "Three duck modes — Fade + Pause, Instant, **or Mute only**" | Two presets, or your own. *Mute only* still exists in `DuckMode` but the pane offers no way to pick it, so documenting it would document a control that is not there |
| Usage | "Auto-pause defaults" table of raw numbers | New `### Presets` (Fade vs Instant, in plain language) and `### Advanced settings` (real ranges, and that moving any slider is what switches the pane to *Custom*) |
| Permissions | Two rows, one naming `NSAudioCaptureUsageDescription` as "Audio Capture", the other claiming the menu bar keeps working without Automation | The two real permissions, why each, exact System Settings paths, and what is lost without each. Automation missing also empties the menu bar: `runAppleScript` returns `nil` on any Apple Event error (`PlaybackModel.swift:331`), so a denial is reported as "no information" |
| Troubleshooting | *All except…* / *Only…*, "Switch to Mute only", wrong literal log path | Current wording, plus three new entries: will-not-enable, the poll-only state dot, and the browser case |

Three new troubleshooting entries are worth reading in full in the README: what
each permission row's button actually does (`Grant…` vs `Open System Settings`,
because macOS will not re-prompt after a refusal), what "Watching by process
only" means (the grant exists, the capability does not — polling cannot tell
silence from sound, so a paused tab can hold the resume for many seconds), and
that a browser is **one** entry — tabs are not listed separately.

I removed the "39 tests" claim in all three places it appeared rather than
recount it, since I did not run the suite.

## 5. Blockers for whoever runs the audio test

1. **The container preferences plist is root-owned and unreadable:**
   `-rw------- 1 root wheel ~/Library/Containers/com.KathirD.sonar/Data/Library/Preferences/com.KathirD.sonar.plist`.
   The script detects this, stops with a clear message and prints the fix, but
   **a human has to run it**:

   ```sh
   sudo chown -R "$(id -un)":staff ~/Library/Containers/com.KathirD.sonar
   ```

2. **The shell that runs the test needs its own Automation grant for Spotify.**
   The script drives `osascript`, so the grant belongs to Terminal/iTerm, not to
   Sonar. Without it the run fails at step 3 and says so.

3. **The first run against a fresh build will stop on two system dialogs**
   (Screen & System Audio Recording, and Automation for Spotify). The script
   cannot answer them, and *Don't Allow* makes the assertions fail for a reason
   that is not a bug.

4. **One test at a time.** Audio, `/Applications/Sonar.app` and Spotify are shared
   state on this machine.

Commands for the designated runner:

```sh
cd /Users/kathirdev/Documents/projects/Sonar
# full: build, stage + install, force Instant, tone, assert, restore
sh scripts/autopause-smoke.sh --build --install --allow-playback

# against the currently installed /Applications/Sonar.app (codesign -v passes, 0.1.0)
sh scripts/autopause-smoke.sh --allow-playback
```

## 6. Required patches — not mine to apply

### 6a. For the owner of `Sonar/Info.plist`

`Sonar/Info.plist:9-10` still ships:

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>Sonar measures other apps' loudness to auto-pause Spotify. Without it, auto-pause falls back to process polling.</string>
```

**The second sentence is now wrong and user-visible.** Without that grant
Auto-Pause cannot be enabled at all (`AutoPausePreferencesModel.canEnable` gates
the toggle and reverts the flag in `didSet`); the poll-only degradation only
happens when the grant exists *and* no audio is reaching the tap. Suggested
replacement:

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>Sonar measures other apps' loudness so it can tell sound from silence before pausing your music.</string>
```

I left `NSAudioCaptureUsageDescription` in place deliberately: the system-audio
prompt is attributed to it, so removing it could remove the prompt.

### 6b. For the owners of the model and the preset

`AutoPausePreset.instant.threshold` is `0.01` and `.fade.threshold` is `0.02`
(`AutoPausePreset.swift:78-83`), but `AutoPausePreferencesModel.presetThreshold`
is pinned to the **Fade** value for every preset:

```swift
static var presetThreshold: Double { Double(AutoPausePreset.fade.threshold) }
```

So `apply(.instant)` persists `0.02` and the engine's `0.01` never reaches a
running app. That is self-consistent today (the model's local `matches` compares
against the same constant, so the pane still labels the values "Instant"), but it
means `AutoPausePreset.threshold` is effectively dead code and the doc comment
above it — "the pane asks the preset rather than keeping a second copy that can
drift" — describes an intent the code does not implement. Either
`presetThreshold` becomes `preset` → `Double($0.threshold)`, or the engine's
instant threshold comes out.

`scripts/autopause-smoke.sh` writes `0.02` (what the app persists) and takes
`PRESET_THRESHOLD` as an env override, so it survives either resolution without an
edit.

## 7. Incident: I quit the running Sonar mid-way through my own verification

While running a partial, non-audio invocation of the script
(`--skip-spotify --no-quit-sonar --skip-launch --skip-assert --skip-log`), its
cleanup path quit the Sonar that the other agent's live audio test was using. The
log shows it between `candidate: poll` and `ducked: poll` at `2026-09-29T02:10:37Z`.
Nothing else was touched: no audio, no Spotify, no `/Applications`, no TCC. The
other agent needs to relaunch Sonar.

**Cause.** Cleanup quit any Sonar that was running when the script started,
reading that as "restore the original state". **Fix.** Cleanup now only ever quits
a copy this script launched (`SONAR_LAUNCHED_BY_US`); an already-running Sonar is
left alone, verified with a fake process named `Sonar`. Two related rules came out
of the same review: cleanup sends Spotify **no** Apple Events at all until the tone
has actually been played (`SPOTIFY_TOUCHED`), so an early failure cannot change
playback it never touched; and the preferences restore is a whole-file copy, so it
puts back the original plist types rather than re-writing numbers as strings.

The `EXIT` trap is the one cleanup path, and it is exercised by every run above.
The `INT`/`TERM` path is wired but was not exercised live — the only long waits in
the script are the ones that need audio.

## 8. What this test does not cover — needs a human

- **The TCC prompts themselves**, and anything about a denied grant.
- **Latency below ~150 ms.** Poll interval plus one `osascript` round trip.
- **The Fade preset.** It needs a 2 s ramp and a 3 s quiet streak, and asserting
  on a volume ramp needs a volume sampler this script does not have.
- **Multi-app and browser cases.** `afplay` is one clean, short-lived, guaranteed
  -loud source. A browser holding an open-but-silent output stream — the exact
  case the README's browser entry describes — cannot be reproduced with a tone.
- **Ownership hand-back**: that a manual pause or volume change makes Sonar stand
  down.
- **The unsandboxed log path** (`~/Library/Logs/Sonar/sonar.log`): a fallback
  branch only.
- **cfprefsd behaviour under a concurrent app save**, and repeat runs on a busy
  machine.

## 9. Note for whoever commits this

- Stage only `scripts/autopause-smoke.sh` and `README.md` from this work. Other
  agents' changes are in the same working tree.
- A rebuild invalidates the TCC grants, so committing this does not affect
  anyone's grant — but **running** the test after a rebuild will, and macOS will
  re-prompt.
- The `docs/PARALLEL-WORK-CONTRACT.md` index needs a row for this report; I did
  not edit that file because it is not mine:

  ```markdown
  | [`AUTOPAUSE-SMOKE-TEST.md`](AUTOPAUSE-SMOKE-TEST.md) | `scripts/autopause-smoke.sh`, `README.md` | You own the Auto-Pause preferences model, `SonarPermissions`, or `Info.plist` (§6 has two required patches), or you are the designated audio-test runner (§5). |
  ```
