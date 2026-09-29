# Auto-Pause preferences pane — agent-ui notes

**Who:** `agent-ui`. **When:** 2026-09-28, alongside the engine rewrite.
**Scope:** the Auto-Pause preferences pane only — `Sonar/Preferences/AutoPausePreferencesView.swift`,
`Sonar/Preferences/AutoPausePreferencesModel.swift`, `Sonar/Engine/SonarPermissions.swift`,
plus `SourceAppIdentity` in `Sonar/Engine/RecentSourcesModel.swift`.

This is a hand-off note, not a design doc. §2 is the part that matters if you touch the
engine: it lists the things the pane now depends on, and what visibly breaks if they move.

---

## 1. What I changed

| File | Change |
|---|---|
| `Sonar/Preferences/AutoPausePreferencesView.swift` | Rewritten. Permissions section first, degraded-state warning, gating, hand-rolled preset rows, Advanced disclosure, mode-aware sources/Heard rows, diagnostics moved to the bottom with a "which detector is driving" line. |
| `Sonar/Preferences/AutoPausePreferencesModel.swift` | Rewritten. Same `autopause.*` keys; added the derived-preset rule, the single-fade control, the inverted sensitivity mapping, the permission gate, and the source-mode copy. |
| `Sonar/Engine/SonarPermissions.swift` | **New.** The permission model, exactly as specified in `PARALLEL-WORK-CONTRACT.md`. |
| `Sonar/Engine/RecentSourcesModel.swift` | Added `SourceAppIdentity` (bundle ID → display name + icon), used by every app row. |
| `Sonar/Engine/SonarLog.swift` | One line, to clear a pre-existing `try?` warning. No behaviour change. |

New persisted key: `autopause.advancedExpanded` (Bool) — whether the Advanced disclosure is
open. Every pre-existing `autopause.*` key is unchanged and still read, so old installs keep
their settings. Nothing outside the Auto-Pause pane changed.

## 2. What other agents must know

### 2.1 The pane reads these engine symbols. If one is renamed, the pane stops compiling.

| Symbol | Used for |
|---|---|
| `AutoPauseController.drivingDetector` (via `SonarEngineHost.drivingDetector`, `@Published`) | The "Detector" diagnostics row, and the degraded "no audio is reaching Sonar" warning. |
| `AutoPausePreset.threshold` | Applied when a preset is picked, and compared when deciding whether the current values still *are* a preset. |
| `AutoPausePreset.matches(mode:activeDuration:quietDuration:fadeOutDuration:fadeInDuration:threshold:)` | The single source of truth for "is this Fade, Instant, or Custom". |
| `AutoPausePreset.mode / .activeDuration / .quietDuration / .fadeOutDuration / .fadeInDuration / .title` | What `apply(_:)` writes and what the Reset button names. |
| `SourceFilterMode` (`.allExcept` / `.watchedOnly`), `SourceFilter`, `DuckMode` | The segmented switch, the "Will pause / Will ignore" verdict, the mode-aware row labels. |
| `SonarEngineHost`: `uiState`, `tapStatusText`, `tapRMS`, `pollActive`, `loudCountdown`, `quietCountdown`, `lastEventText`, `tapIsOperational`, `drivingDetector` | The engine-state row under the toggle, and all of Diagnostics. |

The pane holds **no copies** of any of these. `AutoPausePreferencesModel.currentPreset` is a
pure derived value (`AutoPausePreset.allCases.first { matches($0) }`); there is no stored
"current preset" anywhere, so it cannot desync from the sliders. If you add a field to
`AutoPausePreset`, add it to `matches(_:)` in the model too or the pane will keep calling
hand-tuned settings "Fade".

### 2.2 A bug I hit and fixed, in case the pattern reappears

`AutoPausePreset.threshold` is **not the same for every preset** — Fade 0.02, Instant 0.01.
The model originally kept one `static let presetThreshold = 0.02` and applied it to every
preset. The moment the engine's per-preset values landed, picking "Instant" would have
written 0.02 while the engine considered Instant to be 0.01, so the pane would have flipped
straight to "Custom" on a user who had just clicked a preset. `apply(_:)` now writes
`preset.threshold`, and `AutoPausePreferencesModel.presetThreshold` is a computed
`static var` alias of the Fade value (kept only as the load-time default for a fresh
install). There is a regression assertion for it in §5.

### 2.3 Permission model as implemented

`SonarPermissions` is an `ObservableObject` singleton (`.shared`). Probes and requests all
run off the main thread; only publishing hops back.

- **Screen & System Audio Recording** — preflight `CGPreflightScreenCaptureAccess()`. No
  audio-capture preflight exists in the SDK (`AVAudioApplication.recordPermission` is
  microphone only and is *not* used). Request = `CGRequestScreenCaptureAccess()` **plus**
  restarting the tap, because Apple documents the prompt as implicit in capturing a tap
  (`TapDetector`). `CGPreflight…` is not the truth: the pane's "granted but silent" state
  uses `host.tapIsOperational`, and a granted tap that delivers no buffers shows as
  `tapSilent` with a "Try again" fix.
- **Automation** — `AEDeterminePermissionToAutomateTarget` against `com.spotify.client`
  with `kCoreEventClass`/`kAEGetURL`. Mapping: `noErr` → granted, `-1744` → `needsGrant`
  (the OS will still prompt), `-600` → `targetNotRunning` (Spotify is not running — its own
  state, grey, and deliberately **not** blocking), `-1742`/anything else → `blocked`
  (`Open System Settings`, because the OS will not prompt again). The requesting call passes
  `askUserIfNeeded = true` and runs off the main thread.
- Deep links are exactly the two in the contract. `com.apple.settings.PrivacySecurity` is
  not used — it does not navigate on macOS 27.
- **Live:** 1 s poll plus `NSApplication.didBecomeActiveNotification`, both started and
  stopped with the pane's `onAppear`/`onDisappear`.

**`-600` not blocking is a deliberate call.** There is no grant to make, a Spotify-only
feature has nothing to act on while Spotify is closed, and the next poll settles it either
way. If you disagree, the single place to change is `SonarPermissions.canEnable`.

### 2.4 Interaction with two findings in `AUTOPAUSE-ENGINE-AUDIT.md`

- **S1-6 (driving detector flaps during a tap rebuild).** The pane's warning row is
  suppressed for the first 3 s of *any* poll-only spell, and that timer re-arms on every
  `drivingDetector` change — so a 0–2 s flap during a rebuild never shows a warning, while
  a detector genuinely stuck on poll does (3 s later). If you fix S1-6, the pane needs no
  change; if you make poll-only *mean* something else, this debounce is the thing to revisit.
- **§3b ("a clean stream of digital silence counts as verified").** My "Detector" row reports
  `drivingDetector` verbatim and is neutral about it ("System audio (tap)" /
  "Process polling only"); the claim the audit disputes is the engine's, not the pane's. If
  the gate starts using `TapDetector.lastPeak`, the pane picks the new behaviour up for
  free. I did not add a "measured loudness" claim anywhere.

### 2.5 Coordinated changes other agents are waiting on

- **`AGENT-TESTS-REPORT.md` §3.1** ("`matches` has a hard-coded default that makes the
  Instant preset unreachable") — **already handled on my side; nothing is blocked on
  agent-ui.** The report asks that every call site in `AutoPausePreferencesModel.swift` pass
  the real threshold in the same commit as the signature change. The only app call site is
  `AutoPausePreferencesModel.matches(_:)`, and it already passes
  `threshold: Float(threshold)` explicitly, so deleting the `= 0.02` default compiles
  unchanged. The pane was also never affected by the bug itself, because the threshold it
  compares has always been the live one rather than a default.
- **Adding a field to `AutoPausePreset`** does need a matching change in
  `AutoPausePreferencesModel.matches(_:)` (or the defaulting it, rather than a
  hand-rolled comparison, in case `matches` gains a parameter that the pane cannot supply).

### 2.6 Behaviour the pane will not negotiate

Things that look like bugs and are not, so nobody "fixes" them:

1. **Turning the toggle on is blocked without both permissions, turning it off never is.**
   Someone who just lost a permission still has to be able to switch the feature off.
2. **`enabled` is refused in the `didSet` of the model, not just in the UI.** Writing
   `enabled = true` from anywhere while a permission is missing resets it to `false` and
   does not save.
3. **The rest of the pane is hidden when Auto-Pause is off** — not greyed out. No empty
   headers, no disabled leftovers.
4. **Auto-Pause is not force-disabled at load** if a grant was revoked after enabling. The
   pane reports it at the top instead, which is the point of the top warning.
5. **"Custom" is a derived state, not a menu item.** It appears when the values stop
   matching, it is not tappable, and it flips back by itself if a slider returns to the
   preset value. No toast: a slider drag is continuous, so a toast would either spam or
   arrive too late. It self-announces through the "You set the timings yourself." caption,
   `Reset to <preset>`, and `Undo Fade Length` in the Edit menu.
6. **Preset = mode + all four timings + threshold.** Picking a preset replaces every one of
   them, which the section footer promises.
7. **The loudness slider is inverted on purpose.** The engine compares `rms >= threshold`,
   so a higher threshold is *less* sensitive. Dragging right must mean "picks up more", or
   the label lies. Model: `sensitivityPosition` is `1 - (threshold - lo) / (hi - lo)`.
8. **The source list means opposite things in the two modes**, so the segmented control is
   followed by a plain-English sentence that is recomputed on every change, every Heard row
   carries a "Will pause" / "Will ignore" verdict, and the row action's label comes from
   exactly one function (`sourceActionTitle(isListed:)`) with exactly one mutation path
   (`toggleSource(_:)`). In "All apps" mode that label is `Ignore`, not `Watch` — the old
   label was a lie about what the button did.
9. **`Reset to <preset>` names the target and is disabled when the preset already matches.**
   A reset with nothing to reset is a button that lies.

## 3. What the pane looks like

One `Form`, `.formStyle(.grouped)`, no `ScrollView` (a grouped `Form` is its own scroll
view on macOS). Order, top to bottom:

1. **Permissions** — always, enabled or not.
2. **Degraded-state warning** — only when Auto-Pause is on and something is wrong.
3. **Enable toggle** + state dot + inline blocker + one-click fix.
4. *Everything below is hidden unless Auto-Pause is on:* presets · fade slider · Advanced ·
   which apps · Heard · the list · diagnostics.

Preset modes: **Fade** shows one slider and keeps the rest in a disclosure; **Instant** shows
no sliders at all (a "Use a fade instead" link instead); **Custom** shows every control
inline, because there is nothing left to keep back.

## 4. Microcopy

Everything the pane says, so it is not re-invented inconsistently:

| Where | String |
|---|---|
| Permissions footer | `Both are needed before Auto-Pause can switch on.` |
| Permission, granted | `Granted. Sonar can measure how loud other apps are.` / `Granted. Sonar can pause and resume Spotify.` |
| Permission, missing | `Not granted. Sonar needs this to measure how loud other apps are.` |
| Permission, blocked | `Turned off. Sonar needs this to pause and resume Spotify.` |
| Permission, tap silent | `Granted, but no system audio is reaching Sonar yet.` |
| Permission, no Spotify | `Spotify isn't running, so this is unchecked.` |
| Permission buttons | `Grant…` · `Open System Settings` · `Re-check` · `Try again` |
| Blocker | `Sonar needs Screen & System Audio Recording and Automation before Auto-Pause can switch on.` |
| Toggle | `Pause Spotify when other apps play sound` |
| Toggle footer | `Sonar pauses Spotify when another app makes sound, and starts playing again when it goes quiet.` / `While Sonar holds Spotify, a manual pause, volume change, restart or quit hands playback back.` |
| Warning, permission | `Auto-Pause is on, but something is missing` |
| Warning, poll-only | `Auto-Pause is on, but no audio is reaching Sonar` |
| State row | `Holding Spotify` · `Listening for other apps` · `Watching by process only` · `Idle` |
| Presets | `How Auto-Pause behaves` · `Music eases down and back up. The first and last moments of speech can slip under it.` · `Music cuts out and back in the moment. Nothing is clipped, but the change is abrupt.` · `Custom` / `You set the timings yourself.` · `These values no longer match Fade or Instant. Pick one above to go back to a starting point.` |
| Fade | `Fade length` / `One length for both directions.` · `How gently music steps down for the other app, and back up when it stops.` · `Use a fade instead` |
| Advanced | `Advanced settings` · `Trigger delay` · `Resume delay` · `Loudness sensitivity` · `Only loud sound` ↔ `Even a whisper` · `Which apps count` · `Reset to Fade` / `Reset to Instant` |
| Sources | `Which apps pause your music` · `All apps` · `Only these apps` · `Every app on this Mac can pause your music.` · `Every app can pause your music except Safari.` · `Only 3 apps can pause your music.` · `No app can pause your music yet. Watch one below to start.` |
| Heard | `Heard in the last 3 minutes` · `Will pause` · `Will ignore` · `Nothing is playing right now.` · `Play something in another app and it will show up here.` · `Tabs aren't listed separately — a browser counts as one app.` |
| Row actions | `Ignore` · `Stop ignoring` · `Watch` · `Stop watching` |
| The list | `Ignored apps` / `Watched apps` · `Add an app that isn't listed` · `Not installed on this Mac` |
| Diagnostics | `Detector` → `System audio (tap)` / `Process polling only` |

## 5. How this was verified

The pane cannot be exercised without launching Sonar and touching audio, so it was verified
in a throwaway harness that compiles the pane's own files against the real engine:

```
/var/folders/…/T/opencode/harness/     # SwiftPM app; Sonar is never launched
./Harness.app/Contents/MacOS/Harness --selftest      # 36 model assertions, all pass
./Harness.app/Contents/MacOS/Harness window=N [bottom] [stub-blocked] [stub-notrunning]
```

`window=0` Fade · `1` Custom · `2` Instant · `3` off · `4` enabled with a dead tap, and the
`stub-*` flags override permission state so every state is renderable. Screenshots sit next
to the binary. The self-test covers the parts a screenshot cannot: that a slider derives
Custom, that snapping back re-selects the preset, that sensitivity moves in the intuitive
direction, that each preset's threshold comes from the preset, that an off-preset value
survives a reload, that the source labels match the source mutations, and that `enabled = true`
is refused in both the UI and the model.

Build, at every step:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project SpotMenu.xcodeproj -scheme Sonar -configuration Debug \
  -derivedDataPath /tmp/DerivedData-agentui build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
```

Succeeds with no warning or error from any file the pane owns. The harness is disposable; it
lives outside the repo and nothing in the app depends on it.

## 6. Deliberately not done

- **No Edit-menu wiring.** Undo is registered on the preferences window's own `UndoManager`,
  so it appears if and when a standard Edit menu exists. Adding one is a `Sonar/App` change,
  which is not mine.
- **The sensitivity range is `0.005…0.2` RMS, linear.** The presets now sit at 0.01/0.02, so
  the interesting part of the track is its top ~10%. Narrowing the range would help, but it
  clamps any stored value above the new maximum on load — a migration decision for the owner,
  not a UI decision. Flagged, not done.
- **No `AutoPausePreferencesView` second form in `PreferencesView`.** The pane is a single
  section and no plumbing there changed.
- **No new UserDefaults keys other than `autopause.advancedExpanded`**, and no migration.

## 7. Open for the owner

1. Narrow the sensitivity range (above) — needs a migration decision.
2. If the engine ever publishes *why* the tap is dead (the audit's S1-11 retry loop, S1-7
   wedged `AudioDeviceStop`), the top warning can name it instead of offering a bare
   "Try again". The `DegradedWarning.fix` tuple is where that goes.
3. `AutoPauseEngineHost.swift:49` still has a `Sendable` capture warning; it is not mine and
   was left alone.
