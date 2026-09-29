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
