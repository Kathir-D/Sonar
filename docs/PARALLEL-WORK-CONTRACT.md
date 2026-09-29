# Sonar — parallel-work contract (2026-09-28)

Multiple agents are working on this repo at the same time. **Read this file first.**
If your task says you own a file, that file is yours alone. Never edit a file you do
not own. If you need a change in someone else's file, write it in your final report
as a required patch instead of applying it.

## Repo layout of interest

```
Packages/AutoPauseEngine/Sources/AutoPauseEngine/*.swift   <- OWNER: agent-engine (human session)
Packages/AutoPauseEngine/Tests/AutoPauseEngineTests/*.swift <- OWNER: agent-tests
Packages/AutoPauseEngine/Package.swift                     <- OWNER: agent-engine
Sonar/Engine/SonarEngineHost.swift                         <- OWNER: agent-engine
Sonar/Engine/RecentSourcesModel.swift                      <- OWNER: agent-ui
Sonar/Engine/SonarLog.swift                                <- OWNER: agent-ui
Sonar/Engine/SonarPermissions.swift (NEW)                  <- OWNER: agent-ui
Sonar/Preferences/AutoPausePreferencesModel.swift          <- OWNER: agent-ui
Sonar/Preferences/AutoPausePreferencesView.swift           <- OWNER: agent-ui
Sonar/App/*, Sonar/UI/*, Sonar/StatusItem/*, Sonar/Playback/*  <- UNTOUCHED by all agents
scripts/autopause-smoke.sh (NEW)                           <- OWNER: agent-e2e
scripts/*.sh (existing)                                    <- OWNER: agent-e2e
README.md                                                  <- OWNER: agent-e2e
```

> **Superseded in part.** This file was written before the tap was made to
> deliver audio. The line describing the aggregate device below is WRONG and is
> kept only so the mistake is recognisable: the tap list must be supplied to
> `AudioHardwareCreateAggregateDevice` **at creation** as `{kAudioSubTapUIDKey,
> kAudioSubTapDriftCompensationKey}` dictionaries, and the aggregate must be
> private. See `docs/HOW-AUTOPAUSE-WORKS.md`.

## Verified hardware/OS facts (do not re-litigate)

- Host: macOS 27.0 (26A428), SDK `MacOSX27.0.sdk` inside `/Applications/Xcode.app`.
  `xcode-select -p` points at CommandLineTools, so **every** xcodebuild invocation must set
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- App bundle id `com.KathirD.sonar`, LSUIElement, ad-hoc signed for local runs.
  TCC grants are bound to the ad-hoc code hash, so **a rebuild invalidates the grant** and
  the OS re-prompts. A pending consent dialog is a system dialog owned by the process
  `UserNotificationCenter` with buttons "Don't Allow" / "Allow".
- Audio tests on this machine: only ONE test at a time may touch Spotify / /Applications/Sonar.app /
  Chrome audio. If you are not the designated test runner, do not run them.

## Engine API contract that agent-ui and agent-tests may rely on

agent-engine is implementing exactly this. Signatures are frozen for the duration.

```swift
// TapDetector.swift
public struct TapAudioFormat: Sendable, Equatable {
    public var sampleRate: Double
    public var channels: Int
    public var isFloat: Bool
    public var bitsPerChannel: Int
    public var framesPerBuffer: Int { get }
}

public enum TapMeter {
    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float            // existing
    public static func rms(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        format: TapAudioFormat
    ) -> Float?                                                                     // new
}

extension TapDetector {
    /// True once the IOProc has delivered at least one buffer from the current build.
    /// This — not the tap merely "existing" — is what makes loudness detection trustworthy.
    public var isCapturing: Bool { get }                                             // new
    public var format: TapAudioFormat? { get }                                       // new
    public var lastPeak: Float { get }                                               // new
}

// AutoPauseController.swift
public enum DetectorKind: String, Sendable { case tap, poll }                        // new
extension AutoPauseController {
    /// Which detector actually drives decisions right now. `.tap` only when the tap is
    /// receiving buffers; otherwise poll-only (which cannot measure loudness).
    public private(set) var drivingDetector: DetectorKind { get }                     // new
}

// AutoPausePreset.swift  (unchanged cases: .fade, .instant)
extension AutoPausePreset {
    public var threshold: Float { get }                                               // new
    public func matches(
        mode: DuckMode,
        activeDuration: TimeInterval,
        quietDuration: TimeInterval,
        fadeOutDuration: TimeInterval,
        fadeInDuration: TimeInterval,
        threshold: Float                                                             // new param
    ) -> Bool
}
```

`AutoPausePreset` keeps `mode`, `activeDuration`, `quietDuration`, `fadeOutDuration`,
`fadeInDuration`, `title`, `summary`, `allCases`, `rawValue`, `id`.

## Permission model that agent-ui implements (researched, verified on this host)

Two permissions gate enabling Auto-Pause. Both must be granted.

1. **Screen & System Audio Recording** (system audio capture for the Core Audio tap).
   - Preflight: `CGPreflightScreenCaptureAccess()` (macOS 10.15+, still valid in the 27 SDK).
     On macOS 26/27 a Screen Recording grant is what the tap needs; there is NO public
     audio-capture preflight API in the SDK (`AVAudioApplication.recordPermission` is
     microphone only and is NOT the right API).
   - Request: `CGRequestScreenCaptureAccess()`, plus actually starting the tap, because
     Apple documents the prompt as implicit: "The first time you start recording from an
     aggregate device that contains a tap, the system prompts you to grant the app system
     audio recording permission."
   - Truth = a liveness probe (the tap receiving buffers), never the preflight flag alone.
   - A previously denied process is NOT re-prompted; the UI must offer "Open System
     Settings" instead of a retry button.
2. **Automation** (Apple Events to `com.spotify.client`).
   - Preflight: `AEDeterminePermissionToAutomateTarget(&desc, 'core', 'getd', false)`
     from `<ApplicationServices/AE.h>`, via `AECreateDesc(typeApplicationBundleID, ...)`.
     `noErr` = authorized, `errAEEventWouldRequireUserConsent` (-1744) = not granted yet,
     `errAETargetAddressNotPermitted` (-1742) = blocked by sandbox, `procNotFound` (-600) =
     Spotify is not running (NOT a permission problem — must be a distinct UI state).
   - Request: same call with `askUserIfNeeded = true`, **off the main thread** (it can
     block arbitrarily long while the user answers a prompt).
   - Available from macOS 10.14. `AXIsProcessTrusted` is accessibility and irrelevant.

System Settings deep links (verified to actually navigate on macOS 27; the newer
`com.apple.settings.PrivacySecurity?…` host does NOT work and must not be used):

```
Screen & System Audio Recording: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
Automation:                      x-apple.systempreferences:com.apple.preference.security?Privacy_Automation
```

`CGPreflightScreenCaptureAccess()` flips live when the user grants in System Settings, but
there is no notification; poll it (1 s) while the permission UI is on screen and on
`NSApplication.didBecomeActiveNotification`.

## Audit reports — read before you build on someone else's code

These are read-only reviews, not patches. Nothing in them has been applied, and the
`file:line` references are pinned to the SHA-1s recorded at the top of each report,
so a line number that does not match your working copy means your file is newer than
the report — re-derive the line, not the finding.

| Report | Covers | Read it if |
|---|---|---|
| [`AUTOPAUSE-ENGINE-AUDIT.md`](AUTOPAUSE-ENGINE-AUDIT.md) | All 12 files in `Packages/AutoPauseEngine/Sources/AutoPauseEngine/`, `Sonar/Engine/SonarEngineHost.swift`, `AutoPausePreferencesModel.swift`, the engine tests | You touch any of the above. It has a per-agent "what to do with this" section (§7) listing the specific findings that are yours. |
| [`AUTOPAUSE-PANE-NOTES.md`](AUTOPAUSE-PANE-NOTES.md) | The Auto-Pause preferences pane: `AutoPausePreferencesView.swift`, `AutoPausePreferencesModel.swift`, `Sonar/Engine/SonarPermissions.swift` | You change `AutoPausePreset`, `AutoPauseController.drivingDetector`, `SourceFilterMode`, or anything `SonarEngineHost` publishes. §2 lists every engine symbol the pane depends on and what breaks in the UI if it moves, plus the nine pieces of pane behaviour that look like bugs and are not. |

Two things the engine and the pane have to agree on, both now in the pane notes:

- `AutoPausePreset.threshold` differs per preset (Fade 0.02, Instant 0.01). Anything that
  keeps a single threshold constant of its own will mislabel Instant as "Custom" the moment
  a user picks it.
- The pane derives "Custom" from `AutoPausePreset.matches(…threshold:)`, so a field added to
  a preset has to be added to the pane's `matches(_:)` too, or hand-tuned settings keep
  being labelled as a preset.
- `AGENT-TESTS-REPORT.md` §3.1 (removing the `threshold: Float = 0.02` default from
  `matches`) is **already satisfied on the pane side**: the only app call site,
  `AutoPausePreferencesModel.matches(_:)`, passes the real threshold explicitly, so the
  signature change compiles as-is and nothing is blocked on agent-ui.

Highest-value items in the auto-pause audit, if you only read one section:

- **§2d item 1, one line, ~300 ms:** `stateAndVolume()` is a protocol *extension
  default* (`SpotifyControl.swift:41`), not a protocol requirement, so every call
  through `any SpotifyControl` statically dispatches to the two-read default and
  the single-round-trip AppleScript override is unreachable. The "~0.36 s to pause"
  in commit `321196e` assumed the fast path that does not run.
- **§1 S1-3/S1-4/S1-5, one change, three findings:** the engine tick calls the
  adapter's `*Sync` methods on the engine's own serial queue while
  `SonarEngineHost` calls the async `restore()` on the adapter's queue. That blocks
  the 10 Hz decision loop for a whole fade, allows two threads inside
  `NSAppleScript` at once (commit `b291620` documents that as an
  `EXC_BAD_ACCESS`), and makes every generation-token guard permanently true. The
  async trio at `SpotifyFadeAdapter.swift:84,94,104` already exists; make it the
  only entry point.
- **§1 S1-7, new code:** a wedged `AudioDeviceStop` during sleep leaves
  `TapDetector.tearingDown == true` forever, and `rebuildIfNeeded` then refuses to
  ever build again — the tap is dead for the session with no log line.

Two notes for whoever commits this work:

1. The engine was being rewritten by agent-engine while the audit was running
   (`TapDetector.swift` changed three times; `AutoPauseController.swift`,
   `AutoPausePreset.swift` and `SonarEngineHost.swift` were all rewritten at
   21:03–21:07). Verify the tree builds and the full suite passes before staging,
   and do not bundle a documentation file with another agent's half-finished code.
2. The audit makes no claim about the current test count. Three test files
   document known bugs as expected behaviour with `_KNOWNBUG` suffixes; those are
   the assertions to flip once the corresponding fix lands.

---

## Update 21:30 — agent-tests has finished, 271 tests green

Full test report: **`docs/AGENT-TESTS-REPORT.md`**. Read §0 first — it is a
per-agent summary of what is blocked on whom.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/AutoPauseEngine
# ✔ Test run with 271 tests in 0 suites passed
```

`DEVELOPER_DIR` is required for `swift test` exactly as it is for `xcodebuild`:
CommandLineTools ships no `Testing` module, so a bare `swift test` fails on every
test file. Suite is hardware-free, permission-free, ~2.7 s, verified over 8 runs.

**agent-engine** — five Source bugs in `AGENT-TESTS-REPORT.md` §3.1–3.7 have a test
already asserting the current (wrong) behaviour, so fixing them makes a test change.
§3.1 and §3.2 are one-liners. §3.4 (the missing `_restoreInProgress`) is new and is
not in the audit.

**agent-ui** — **§3.1 is a coordinated change.** `AutoPausePreset.matches` will lose
its `threshold: Float = 0.02` default, because that hard-coded 0.02 makes
`AutoPausePreset.instant.matches(...)` always false — the Instant button can never
render as selected. Every call site in `AutoPausePreferencesModel.swift` must be
updated in the same commit or the project will not compile.

**agent-e2e** — nothing needed from agent-tests; no audio, Spotify, permissions or
scripts were touched. `scripts/autopause-smoke.sh` is still yours.

**agent-tests** — nothing further outstanding. The one gap that needs a source
change first is §3.7 (`AutoPauseController.tap` typed as concrete `TapDetector?`),
which makes the positive tap-drives half of the detector contract untestable. Two
tests are written and parked behind `#if TAP_FAKES`; they compile as-is once the
`TapSignalSource` protocol lands.
