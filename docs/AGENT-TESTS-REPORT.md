# Auto-Pause engine — test report, agent-tests

Test-authoring pass over `Packages/AutoPauseEngine`. **Everything below is either a
test I wrote or a patch I did not apply.** No file under `Sources/` or `Sonar/` was
edited.

- **Author:** agent-tests
- **Date:** 2026-09-28, 21:30 CDT
- **Ownership:** `Packages/AutoPauseEngine/Tests/AutoPauseEngineTests/**` (exclusively)
- **Git HEAD:** `2e6bf0a` ("docs: add parallel-work contract")
- **Companion:** `docs/AUTOPAUSE-ENGINE-AUDIT.md` (agent-audit, read-only). This
  report overlaps its §5 test-gap list and §6 dead-weight list; where they agree I
  say so rather than restating the argument.

## 0. For the other agents, up front

**agent-engine** — five of the six Source bugs below are in your files, and three
of them already have a failing-or-asserting-currently-wrong test waiting. The
shortest wins are the first two, both one-liners. §3.1 will break
`AutoPausePreferencesModel` when you fix it, so coordinate with **agent-ui**.

**agent-ui** — `AutoPausePreferencesModel.swift` calls `AutoPausePreset.matches`.
§3.1 removes that method's `threshold` default. Land those together or the
project will not compile. Audit §6 item 11 is also yours and I agree with it.

**agent-e2e** — nothing needed from me; I have not touched audio, Spotify, the
system permission store, or any script. `scripts/autopause-smoke.sh` is yours.
The hardware-gated tests below (`SONAR_TAP_SMOKE`, `SONAR_TAP_AUDIO`) are the
in-process equivalents if you would rather assert live from a script.

**Whoever commits this** — the engine files changed *underneath* my working tree
three times while I worked (`TapDetector.swift` 756 → 1208 lines,
`AutoPauseController.swift` 185 → 233, `SpotifyFadeAdapter.swift` 332 → 374).
I re-ran the suite after each and it is green against the final state, but do
verify before staging. Only stage `Tests/AutoPauseEngineTests/**` and this file.

## 1. How to run it

```sh
cd /Users/kathirdev/Documents/projects/Sonar
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/AutoPauseEngine
```

```
✔ Test run with 271 tests in 0 suites passed after 2.956 seconds.
```

`DEVELOPER_DIR` is mandatory. `xcode-select -p` points at CommandLineTools, which
ships no `Testing` module, so without it every test file fails with
`error: no such module 'Testing'`. The parallel-work contract already documents
this for `xcodebuild`; it applies to `swift test` identically.

Verified over 8 consecutive runs, no flakes, ~2.7 s wall clock. No hardware, no
permission, no network, no AppleScript, no real sleeps over 5 ms. The only
environment-gated tests are two at the bottom of `TapDetectorTests.swift`, both
guarded by a variable that is unset in CI.

Conventions followed from the existing suite: swift-testing (`@Test`/`#expect`),
pure value types with injected `now: Date`, hand-rolled `FakeSpotifyControl` /
`RecordingPoll` fakes, and the synchronous `tick()` as the driver. One important
departure: `TapMeterTests` could not use its intended `AudioBufferList` builder,
because the SDK's only allocator is `AudioBufferList.allocate(maximumBuffers:)`
(there is no `UnsafeMutableAudioBufferListPointer.allocate`, and no `deallocate`).
`TestSupport.swift` wraps it and frees the raw pointers in `deinit`.

## 2. Coverage table

| File | Tests | Behaviour pinned | Status |
|---|---|---|---|
| `TestSupport.swift` | — | `TestBufferList` builds a real `AudioBufferList` with settable `mNumberChannels`/`mDataByteSize`; `TestFormat` + block builders | new (support) |
| `CoreAudioProbe.swift` | — | Read-only HAL access. Never creates, destroys or starts a device | new (support) |
| `TapMeterTests.swift` | 29 | Interleaved f32, **non-interleaved f32 (one buffer per channel — what a tap actually delivers)**, int16 normalised to full scale, `-0.0` → exactly `+0`, degenerate input → **nil, never 0**, starved pair uses the usable channel, partial trailing sample truncated, sub-sample byte size → nil, array/list meter agreement | rewritten |
| `TapAudioFormatTests.swift` | 16 | `TapAudioFormat(asbd:)`: float32/int16 parse, non-interleaved flag, zero-channel clamp; **rejects** AAC, 24-bit, 64-bit double, unsigned. `frames(perBufferByteSize:)` for both layouts | new |
| `TapSmootherTimingTests.swift` | 25 | Threshold `>=` at the boundary; zero/negative-threshold footguns; `activeDuration` inclusive and measured from the *first* loud sample; `gapTolerance` inclusive at exactly 0.75 and one eighth more; a dip does not refund a served dwell, a gap does; `reevaluate` cannot invent loudness; `gapTolerance == 0`; whole episode at 10 Hz (first 1.0, last 6.6, 57 active samples); live config mutation | rewritten |
| `FusionTimingTests.swift` | 29 | Streak origins; `>=` boundaries at 1.0/2.0/3.0; zero durations still require an observation; no credit for unobserved time; one opposing sample resets either streak; alternating never fires; countdown start anchoring; `reset` idempotence; `AudioSignal` with nil RMS still counts; missing detectors are silent; whole episode at 10 Hz (duck 1.0, resume 5.1); source labels never change mid-episode; defaults == fade preset; live duration mutation | extended |
| `ControllerTickTests.swift` | 19 | One candidate line per episode (5 in a row); adapter events forwarded incl. relinquish reason and `skippedNotPlaying`; no resume when never paused; a disabled engine is *completely* inert (no scan, no AppleEvents); poll refreshed every tick; ticking never starts/stops detectors; `stop()` re-arms, clears streaks, and is safe unticked; source label agrees across both logs; reconcile throttle — allowed *and* throttled; reconcile off when unowned | extended |
| `ControllerDetectorPreferenceTests.swift` | 13 | **The tap-wiring regression.** `drivingDetector == .poll` before any tick, with no tap, and with a tap that has never delivered a buffer. A tap firing `onStatusChange?(.active(rms: 0.9))` still loses the vote — the exact shape of the zero-stream aggregate. `.unavailable` reports its reason and poll still works. `.tapReady` alone never ducks. Trust is revocable. Poll keeps refreshing regardless. 2 tests behind `#if TAP_FAKES` for the positive path | new |
| `TapDetectorTests.swift` | 15 | `isCapturing`/`format`/`lastPeak` all false/nil/0 before a buffer arrives; `latestSignal` seeded inactive (never nil); stop-without-start is inert; constructing detectors registers no HAL device; a leaked zero-stream "Sonar auto-pause" aggregate is a tripwire; "no input stream" vs a permission failure stay distinguishable; detector names agree with `DetectorKind` raw values; 2 hardware-gated liveness tests | rewritten |
| `PollRulesTests.swift` | 32 | `isExcluded`: self pid, responsible-pid-to-self, Spotify by raw *or* responsible bundle (name alone insufficient), daemon names exact-only; excluded sets pinned as literals; one bundle-id constant shared with the adapter. `SourceFilter`: both modes, responsible-bundle matching, prefix/substring near-misses, empty-list edges, orphan fallback, `Equatable` (so the tap can skip rebuilds). Composition: exclusions beat user rules, order preserved, idempotent, non-mutating. Live scan asserted on *shape* only | rewritten |
| `PresetMatchingTests.swift` | 19 | Every single-field deviation rejected (mode, active, quiet, fadeOut, fadeIn, threshold); threshold tolerance 1e-4 vs timing 1e-3; "exactly one preset claims a configuration" checked cross-preset; preset case set; threshold sanity (0 < t < 1, instant < fade, fade == `TapConfig` default, inside a slider range); the default-argument bug | extended |
| `SpotifyFadeAdapterOwnershipTests.swift` | 41 | `skippedNotPlaying` for paused/stopped/unknown, transport failure on duck *and* restore; restore is a zero-call no-op in all three modes; duck idempotence in all three modes; mid-fade and mid-fade-in reconcile; relinquish on quit/restart/manual resume/volume change/unreadable volume; instant never writes volume; mute-only never plays; pre-duck volume swept over 6 levels; zero-duration fade is one write; fade is monotonic; 10 episodes leave no stale state; generation-token supersede on both paths with baseline controls; the one-AppleEvent dispatch bug | extended |
| `PresetAndThrottleTests.swift` | 16 | Preset values, summaries describe the real numbers; raw values stable for every persisted enum; `AudioSignal` default RMS is nil; `FusionDecision`/`AudioSignal` equality; the batched `stateAndVolume` script is genuinely one round trip | rewritten |
| `FadeAdapterTests.swift` | 14 | `FakeSpotifyControl` gains `volumeUnreadable` (nil ≠ 0). **No assertion changed** | extended (1 field) |
| `FusionTests.swift` | — | Deleted. Strictly subsumed by `FusionTimingTests.swift`, which pins the same state machine at exact binary-fraction boundaries instead of real-clock 0.9/1.0/2.9/3.0 offsets | removed |
| `PollDetectorTests.swift` | — | Deleted. All 7 tests carried into `PollRulesTests.swift`; its `runningOutputProcessesDoesNotCrash` (`#expect(found.count >= 0)`) was tautological and is replaced with per-entry invariants | removed |

**271 total**, up from 57. No existing assertion was weakened or deleted; the two
removed files were full supersets, and the one tautological test was replaced
rather than ported.

### The regression test for the tap-wiring bug, in one place

The bug was that the aggregate was built with a name and UID only, the tap
attached afterwards, `kAudioDevicePropertyStreams == 0`, no input, `AudioDeviceStart`
answering `'nope'` — and the detector still reported `.active` while delivering
nothing. `isCapturing` is now the only thing that grants the tap the vote.

So the pinned invariant is: **`status == .active` is not evidence.** A controller
holding a tap that has never delivered a buffer reports `.poll`, feeds poll to
fusion, and emits a candidate labelled `"poll"` even when the tap's status
callback claims a loud RMS. See
`ControllerDetectorPreferenceTests.aTapReportingActiveWithNoBuffersIsStillNotTrusted`.

The positive case — a *capturing* tap reporting `.tap` and deciding alone — is
blocked by §3.7. Both tests are written and left behind `#if TAP_FAKES` so they
compile as-is once the seam lands.

## 3. Bugs found in Sources/ — patches only, not applied

### 3.1 `matches` has a hard-coded default that makes the Instant preset unreachable
`AutoPausePreset.swift:98` — `threshold: Float = 0.02`, which is `fade`'s value.
Every call site that omits it compares against 0.02 regardless of the receiver.
`instant.threshold` is 0.01, so **`AutoPausePreset.instant.matches(...)` without a
threshold is always false** — "Instant" can never render as selected. And asking
whether a user at 0.05 is still on "Fade" answers yes, silently relabelling
hand-tuned settings. This is precisely the false positive the UI derives "Custom"
from. Pinned by `theDefaultThresholdArgumentIsTheFadePresetsValue`.

```diff
-        threshold: Float = 0.02
+        threshold: Float
```

**Blocks on agent-ui:** update every call site in
`Sonar/Preferences/AutoPausePreferencesModel.swift` in the same commit.

### 3.2 Mute-only relinquishes ownership on the first reconcile
`SpotifyFadeAdapter.swift` `reconcileImpl` — `if state == .playing && !duckInProgress`.
Mute-only never pauses, so "playing" *is* our own state, and the first reconcile
hands the volume back mid-episode. The controller reconciles on a `.hold` tick,
which happens as soon as one sample drops and the loud streak restarts, so any
single missed sample makes the music blare back. Pinned by
`muteOnlyLosesOwnershipOnTheFirstReconcile_KNOWNBUG` and
`muteOnlyLosesOwnershipOnTheFirstOfManyReconciles_KNOWNBUG`.

```diff
-        if state == .playing && !duckInProgress {
+        if state == .playing && mode == .fadeAndPause && !duckInProgress {
```

### 3.3 Mute-only restore reports `.manuallyResumed` instead of `.restored`
`restoreImpl`, `case .playing:` — same root cause as 3.2. The volume is restored
correctly but the event is wrong, so the log tells the user they did something they
did not. Pinned by `muteOnlyReportsAVolumeChangeAsAManualResume_KNOWNBUG`. Fixed by
branching on `mode` in `restoreImpl` the same way as 3.2.

### 3.4 `duckInProgress` is not set during a restore
`restoreImpl` never sets it, so a reconcile landing inside a fade-in sees
`state == .playing && !duckInProgress` and emits a false `.manuallyResumed`. The
volume still ends up correct and ownership is released either way, so the damage is
a misleading log line plus swallowed user actions. **New, not in the audit's list.**
Pinned by `aReconcileDuringTheFadeInDoesNotStrandTheVolumeAtZero_KNOWNBUG`. Needs a
`_restoreInProgress` flag set around the fade-in and checked alongside
`duckInProgress`.

### 3.5 `stateAndVolume` is a protocol extension default, never dispatched
`SpotifyControl.swift:41`. Calls through `any SpotifyControl` statically bind to
the extension, so `AppleScriptSpotifyControl`'s one-round-trip override is
unreachable from the adapter. Every duck and restore costs two AppleEvents where
the code's own comment says one — the "instant" vs "noticeably late" gap. The audit
found this independently as S1-1; we agree. Pinned by
`stateAndVolumeIsNotDispatchedThroughTheExistential_KNOWNBUG`.

```diff
-public extension SpotifyControl {
+public protocol SpotifyControl: Sendable {
     static var spotifyBundleID: String { get }
     ...
+    func stateAndVolume() -> (state: SpotifyPlayerState?, volume: Int?)
 }
+
+public extension SpotifyControl {
     static var spotifyBundleID: String { "com.spotify.client" }
     func stateAndVolume() -> (state: SpotifyPlayerState?, volume: Int?) { (playerState(), volume()) }
 }
```

### 3.6 Instant mode overwrites a volume the user changed
`restoreVolumeIfUntouched` — in instant mode `_duckedVolume` stays nil, so it
cannot tell "the user moved the slider" from "we own the volume" and writes the
pre-duck volume back. The user's 42 becomes 70. Also found as S1-2. Pinned by
`instantManualResumeOverwritesAUserVolumeChange_KNOWNBUG`. Instant needs to record
the volume observed at duck time as "do not clobber".

### 3.7 `AutoPauseController.tap` is the concrete `TapDetector?`, so the `.tap` path is untestable
`AutoPauseController.swift:40`. With `TapDetector` being `final` and `isCapturing`
a read-only property over private state set only by a real IOProc, there is no way
to inject a capturing tap. The positive half of the detector-preference contract —
`.tap` drives, and poll cannot overrule it — cannot be tested at all today. This is
the audit's §5 rank-1 gap; we converged on the same conclusion from opposite
directions.

```diff
+public protocol TapSignalSource: HybridDetector {
+    var isCapturing: Bool { get }
+}
+
 public final class TapDetector: HybridDetector, TapSignalSource, @unchecked Sendable {
```

```diff
-    public var tap: TapDetector?
+    public var tap: (any TapSignalSource)?
```

Then `#if TAP_FAKES` in `ControllerDetectorPreferenceTests.swift` compiles unchanged
(just add `TapSignalSource` to the fake's conformances).

### 3.8 Dead branches, dead cases, comments that now lie

- `FusionState.swift:51` — `case (false, false): return .hold // unreachable`.
  Genuinely unreachable and self-documented. `default: return .hold` is cleaner and
  drops a branch a reviewer has to reason about.
- `HybridDetector.swift:24` — "Full implementations land in tasks 5 (poll, SmartPause
  MIT port) and 6 (tap…)". Both landed long ago. Stale.
- `HybridDetector.swift:15` — `AudioSignal.at` is written and never read by any
  engine code. The detector seeds `_latest` once and never re-stamps it, so `at` is
  the same value forever. Either stamp it on publish or drop the field.
- `RelinquishReason.wasPausedAlready` and `.notOwned` (`SpotifyFadeAdapter.swift:16,21`)
  are never constructed. `skippedNotPlaying` covers the first; the `guard` in
  `restoreImpl` covers the second. Both are dead enum cases. I pinned their raw
  values in `relinquishReasonsAreStable` so removing them becomes a visible decision
  rather than a silent one.
- `AudioActivityTracker.shared` and `ActivationTracker.shared` are unreferenced inside
  the package; `PollDetector` uses its own instance. (The audit's §6 items 1–2 make
  the stronger case that both classes are dead outright and `ActivationTracker` also
  has an unsynchronised-write bug. Agreed; deletion is agent-engine's call.)
- `TapDetector.swift:10` — the file header still describes the *old* wiring: "aggregate
  device … with the tap attached via `kAudioAggregateDevicePropertyTapList`". The
  fix supplies the list at creation time, and `attachTap(uid:to:)` is now uncalled.
  **This one is worth fixing for its own sake**: the comment contradicts the code
  and points directly at the bug that was just fixed, so it is a trap for the next
  reader.
- `TapDetector.lastRMS` and `TapDetector.lastPeak` now overlap. `lastPeak` is the
  documented one to use for proof-of-signal; `lastRMS` reads `_latest.rms`. Not a
  bug, but a reader will not know which to trust.

## 4. Tautological or wrong existing tests, called out

- **`PollDetectorTests.runningOutputProcessesDoesNotCrash`** — `#expect(found.count >= 0)`
  cannot fail. Replaced with per-entry invariants (positive pid, positive responsible
  pid, non-empty resolved name) and a second test that Sonar and Spotify never appear
  in the *filtered* output.
- **`SpotifyFadeAdapterOwnershipTests.muteOnlyNeverPlaysOrPauses`** asserts
  `log.reasons == [.manuallyResumed]`, i.e. it asserts the bug. Not wrong as a
  current-behaviour record, but the name reads like a statement of intent. I kept
  the assertion and made the comment say explicitly that the intended event is
  `.restored`.
- **`ControllerTickTests.controllerRefreshesPollOnEveryTick`** passes for the wrong
  reason in one direction: it would also pass if poll were never called at all,
  because the count is what it asserts. It is fine as written (it does assert the
  exact count) but it does not prove poll is what *fusion* saw. The candidate-label
  assertions in the new detector-preference file close that gap.
- **`PresetAndThrottleTests.reconcileIsThrottledWhileOwned`** used `<= 1`, so it
  passed whether the throttle worked or reconcile never ran at all. I added
  `reconcileIsAllowedAgainOnceTheIntervalHasElapsed` as the control case, and both
  new controller tests explicitly note that `.candidate` ticks never reach the
  reconcile branch — a trap I fell into while writing them.

## 5. Tests deliberately not written, and why

- **A capturing tap driving decisions.** Needs a real IOProc, a permission grant
  and a device. Blocked by 3.7. Both tests written and parked behind `#if TAP_FAKES`.
- **Any assertion on live process or audio content.** `AudioDetector.runningOutputProcesses()`
  is machine state; asserting *which* apps are playing would fail in CI. Asserted on
  shape instead, which holds on every machine.
- **`TapDetector.buildTap` / `readInputFormat` / `waitForAggregateReady` /
  `startWithRetry`.** All `private`, all build a real device. I test the invariant
  around them rather than the wiring. `CoreAudioProbe` reads the machine's existing
  aggregates for a zero-stream tripwire without creating one. I also removed a
  `start()`/`stop()` pair I had originally written after it proved flaky: on this
  machine the Screen Recording grant happens to be live, so a real tap built and a
  real IOProc ran, and `isCapturing` legitimately became true. The suite does no
  hardware work; the liveness path is behind `SONAR_TAP_SMOKE` / `SONAR_TAP_AUDIO`.
- **A `.tap`-vs-`.poll` decision-latency assertion.** Would need `Date()` injection
  into `tick()`, which does not exist. `FusionTimingTests` pins the timing with
  injected timestamps, and the end-to-end tick test asserts the decision *points*
  (1.0 / 5.1) rather than a wall-clock duration.
- **Ordering guarantees on the adapter's serial queue.** It takes an `NSLock` around
  state but runs the body on a GCD queue; ordering is not observable deterministically
  from a test. The existing `volumeSetHook` / `rereadHook` already cover the
  interleavings that matter, and the generation-token tests use them well.
- **`AudioActivityTracker` notification handling.** Needs Core Audio property
  listeners firing — hardware and OS-timing dependent. `observe(playing:)` is pure
  over a `Set` but is only reachable via `activeSources()`, which scans the HAL.
  The audit's S1-8 mutation-during-iteration bug in that file is real and worth a
  test; it needs the pure function split out of the listener path first.

## 6. Statement of changes

Files I created or modified — all under
`Packages/AutoPauseEngine/Tests/AutoPauseEngineTests/`:

- **Created (11):** `TestSupport.swift`, `CoreAudioProbe.swift`,
  `TapMeterTests.swift`, `TapAudioFormatTests.swift`, `TapSmootherTimingTests.swift`,
  `FusionTimingTests.swift`, `ControllerTickTests.swift`,
  `ControllerDetectorPreferenceTests.swift`, `TapDetectorTests.swift`,
  `PollRulesTests.swift`, `PresetMatchingTests.swift`,
  `SpotifyFadeAdapterOwnershipTests.swift`, `PresetAndThrottleTests.swift`
- **Modified (3):** `FadeAdapterTests.swift` (one new field on the fake),
  `PresetAndThrottleTests.swift`, `TapDetectorTests.swift`
- **Deleted (2):** `FusionTests.swift`, `PollDetectorTests.swift` — both strict
  supersets elsewhere, as itemised in §2
- **Created outside Tests:** `docs/AGENT-TESTS-REPORT.md` (this file) and a pointer
  appended to `docs/PARALLEL-WORK-CONTRACT.md`

**Nothing else was touched.** No file under `Packages/AutoPauseEngine/Sources/` or
`Sonar/`. No commit, no `git add`, no push — the working tree is left for the human
to stage, because several other agents are committing concurrently and a blanket
`git add -A` from me would have swept up their half-finished work.

**No system state was touched:** no permission grant requested, no TCC change, no
Spotify launched or quit, no audio device created or destroyed, no network, no
AppleScript executed.
