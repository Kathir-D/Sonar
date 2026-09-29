# Auto-Pause engine audit — agent-audit, job 3

Read-only review of the auto-pause feature. **No file in this repository was
edited, created, deleted, built, installed or run by the auditor.** Nothing below
is applied; every fix is a required patch for the owning agent.

- **Auditor:** agent-audit
- **Date:** 2026-09-28, 21:15 CDT
- **Scope:** `Packages/AutoPauseEngine/Sources/AutoPauseEngine/*.swift` (12 files),
  `Sonar/Engine/SonarEngineHost.swift`, `Sonar/Engine/RecentSourcesModel.swift`,
  `Sonar/Engine/SonarPermissions.swift`, `Sonar/Preferences/AutoPausePreferencesModel.swift`,
  and `Packages/AutoPauseEngine/Tests/AutoPauseEngineTests/*.swift`
- **Git HEAD when written:** `2e6bf0a` ("docs: add parallel-work contract")

## Snapshot this audit is pinned to

The engine was being actively rewritten while it was read. `TapDetector.swift`
changed three times, and `AutoPauseController.swift`, `AutoPausePreset.swift` and
`SonarEngineHost.swift` were all rewritten at 21:03–21:07. Every `file:line` below
is against these SHA-1s. **If a line number does not match what you see on disk,
your file is newer than this report — re-derive the line, not the finding.**

| File | SHA-1 | Lines at audit time |
|---|---|---|
| `AudioActivityTracker.swift` | `05c3a8b` | 139 |
| `AudioDetector.swift` | `cbff4b9` | 105 |
| `AutoPauseController.swift` | `bd21943` | 209 |
| `AutoPauseEngine.swift` | `7256fcb` | 17 |
| `AutoPausePreset.swift` | `dc9448d` | 115 |
| `FusionState.swift` | `276dc50` | 66 |
| `HybridDetector.swift` | `6539022` | 46 |
| `PollDetector.swift` | `33e445c` | 174 |
| `SpotifyControl.swift` | `46d64dd` | 155 |
| `SpotifyFadeAdapter.swift` | `5043aca` | 332 |
| `TapDetector.swift` | `bed85e8` | 1042 |
| `Sonar/Engine/SonarEngineHost.swift` | `0e1e1ad` | 199 |
| `Sonar/Preferences/AutoPausePreferencesModel.swift` | `8a23c08` | — |
| `Sonar/Engine/RecentSourcesModel.swift` | `28ff982` | 118 |

### Findings that were fixed *while the audit was running*

These were real when found and are recorded so nobody re-investigates them. They
are **not** in the ranked list.

| Was | Now |
|---|---|
| `TapDetector.attachTap` referenced `TapError.attach`, a case that no longer existed — the package did not compile | resolved; `attachTap` deleted, tap list now supplied at aggregate creation |
| `_isCapturing`, `_lastPeak`, `ioProcCallbacks` were never reset between builds, so a rebuilt tap inherited the previous run's proof of life | `tearDownTap()` now clears them (`TapDetector.swift:888-895`) |
| `TapConfig.activeDuration` was left at its 1.0 s default, so the tap's dwell stacked with fusion's and "Instant" took >1 s | `SonarEngineHost.swift:86` now sets `tapConfig.activeDuration = 0` |
| `gapTolerance` 0.75 s doubled the resume latency on top of `quietDuration` | `SonarEngineHost.swift:90` now sets it to 0.15 |
| `drivingDetector` did not exist; the pane inferred it from `tap.status` | added (`AutoPauseController.swift:71,80,147`; `SonarEngineHost.swift:30,166`) |
| A failed tap build was never retried, so granting the permission changed nothing until relaunch | `scheduleRetry()` added (`TapDetector.swift:479`) |

---

## Executive summary

The five things most likely to make "instant auto-pause" fail for a real user, in
order of how badly they hurt. **First: the duck path pays two AppleScript round
trips where the code claims one.** `stateAndVolume()` is a protocol *extension
default* (`SpotifyControl.swift:41`), not a protocol requirement, so every call
through `any SpotifyControl` is statically dispatched to the two-read default and
can never reach `AppleScriptSpotifyControl`'s one-round-trip override
(`SpotifyControl.swift:119`). At the ~300 ms per event measured in commit
`321196e` that is 300 ms of pure waste on both the duck and the resume, and the
"0.36 s" figure in that commit's own message is not reproducible by the code that
shipped with it. **Second: in Fade mode the engine's 10 Hz decision loop is
blocked for the entire fade.** `AutoPauseController.tick()` calls
`adapter.duckSync` on the engine's serial queue (`AutoPauseController.swift:161`),
and `fade()` is a `for` loop of `steps = duration / 0.1` iterations each doing an
AppleScript `set sound volume` plus a `Thread.sleep`
(`SpotifyFadeAdapter.swift:299-312`). A nominal 2 s fade is 20 AppleEvents; no
fusion decision can be evaluated for any of them. **Third: the sync/async split
means two threads can be inside `NSAppleScript` at once.** The controller uses
only the `*Sync` variants (engine queue) while `SonarEngineHost.apply` uses the
async `restore()` (adapter queue) — commit `b291620` documents that `NSAppleScript`
reliably segfaults on a GCD worker thread, so two is strictly worse than one.
**Fourth: and as a corollary, the generation-token machinery is dead in
production.** `nextGeneration()` is only reachable from `duck(source:)` and
`restore()`; production never calls `duck(source:)`, so every
`generation == currentGeneration()` guard in the adapter is permanently true and
the documented protection against interleaved cycles does not exist.
**Fifth: even with the tap fully working, the feature's core promise is
unachievable in poll-only mode and nobody in the code acts on that.** Poll cannot
distinguish silence from sound (proved in commit `5d7e621`: 45 s of digital
silence still read as loud), so when the tap is unavailable — TCC denied, a
starved aggregate, no default output device, an AirPods switch — a silent app
pauses the music *and the resume never comes*, leaving the user's Spotify paused
indefinitely while the other app makes no sound. That is the worst user-visible
outcome in the product and the code has no reflex for it.

---

## 1. Correctness bugs

### S1-1 · The batched state+volume read is never used in production

`SpotifyControl.swift:41` (extension default) vs `:119` (class override); called
from `SpotifyFadeAdapter.swift:177`, `:222`, `:273`.

`stateAndVolume()` is declared only in `public extension SpotifyControl`.
Protocol-extension members are statically dispatched through an existential, so
`control.stateAndVolume()` where `control: any SpotifyControl`
(`SpotifyFadeAdapter.swift:47`) always runs the two-read default.
`AppleScriptSpotifyControl.stateAndVolume()` satisfies no protocol requirement, so
it is unreachable through the erased type.

*Read and verified from the source* — the protocol body (`:19-31`) has no
`stateAndVolume`. Independently confirmed by the test
`stateAndVolumeIsNotDispatchedThroughTheExistential_KNOWNBUG`
(`SpotifyFadeAdapterOwnershipTests.swift:560`), which asserts the current broken
behaviour and spells out the intended assertions.

The comment at `SpotifyFadeAdapter.swift:174-176` — "One AppleEvent instead of
two: … A round trip costs ~300 ms here, so this alone is the difference between
'instant' and 'noticeably late'" — describes code that does not run.

**Fix:** add `func stateAndVolume() -> (state: SpotifyPlayerState?, volume: Int?)`
to the `SpotifyControl` protocol body. Keep the extension as the default so fakes
still compile. One line; highest ratio in this audit.

### S1-2 · Instant mode overwrites a volume the user changed

`SpotifyFadeAdapter.swift:227`, `:232` → `:285-291`.

`duckImpl` in `.instant` never writes the volume, so `_duckedVolume` stays `nil`
(`:198-202`; only the `.fadeAndPause` and `.muteOnly` branches call
`setDuckedVolume`). In `restoreImpl` the `.playing` and `.stopped` branches call
`restoreVolumeIfUntouched(ownedVolume: owned.volume, duckedVolume: owned.ducked)`.
Inside, the guard is `if let current = control.volume(), let ducked = duckedVolume`
— `ducked` is nil, so the "user moved it" test is **skipped** and
`control.setVolume(want)` runs unconditionally.

Sequence: Spotify at 70. Another app makes noise, instant mode pauses. The user
drags the Spotify volume to 42 and presses play. The next reconcile reads
`.playing` and writes 70. The user's 42 is gone.

Violates the module's own contract at `SpotifyFadeAdapter.swift:30-32` ("any
manual pause/volume change … relinquishes ownership (volume is preserved, never
clobbered)"). Pinned by
`instantManualResumeOverwritesAUserVolumeChange_KNOWNBUG` (`:396`).

**Fix:** in `.instant`, do not capture volume in `takeOwnership` (pass `nil`) and
skip both `restoreVolumeIfUntouched` calls in `restoreImpl`. Extend
`instantModeNeverTouchesTheVolume` (`FadeAdapterTests.swift:278`) to change the
volume mid-duck; it passes today only because its scenario never does.

### S1-3 · The engine's decision loop blocks for the whole fade

`AutoPauseController.swift:161`, `:164`, `:166` →
`SpotifyFadeAdapter.swift:171-209`, `:299-312`.

`tick()` runs on the serial queue `sonar.autopause-engine` and calls
`duckSync`/`restoreSync`/`reconcileSync` directly. In `.fadeAndPause`, `duckImpl`
calls `fade(to: 0, over: fadeOutDuration, …)`, which loops
`max(1, Int(duration / fadeStepInterval))` times; with shipped defaults
(`fadeOutDuration` 2.0 s, up to 5.0 s from
`AutoPausePreferencesModel.swift:9`, `fadeStepInterval` 0.1) that is 20–50
iterations, each an AppleScript `set sound volume` plus `Thread.sleep(0.1)`. The
engine queue is unavailable for the whole thing and the 10 Hz timer
(`AutoPauseController.swift:102`) just backs up.

*Cost:* commit `fabc0c1` documents this exact class of bug costing "~4.3s on
resume" from `reconcileSync` before it was throttled; the fade is the same failure
with a 20× multiplier. The wall-clock fade is `steps × (0.1 s + setVolumeCost)`,
**not** `fadeOutDuration`. `fabc0c1` reports observing "100->0 over 2.3s", which
is only consistent with `set sound volume` being far cheaper than the probe — so
**the per-call cost is not measured and I could not measure it** (no build/run
permitted). The AppleEvent *count* is certain.

**Fix:** the controller must use the async trio (`adapter.duck(source:)`,
`restore()`, `reconcile()`), which already exist at `SpotifyFadeAdapter.swift:84`,
`:94`, `:104`. Do **not** do this alone — see S1-4.

### S1-4 · Two threads inside `NSAppleScript` concurrently

`AutoPauseController.swift:161-166` (engine queue) vs `SonarEngineHost.swift:102`
(main → adapter queue); contract comment at `SpotifyFadeAdapter.swift:26` ("All
control calls happen on one private serial queue (never main)").

`SonarEngineHost.apply` calls `adapter.restore()` — async on `sonar.spotify-fade`
— from the main thread. The engine tick calls `adapter.duckSync` on
`sonar.autopause-engine`. The adapter's `lock` protects the ownership fields, but
the `SpotifyControl` calls are unguarded, so both threads can be inside
`NSAppleScript(source:).executeAndReturnError` at once.

Trigger: a video starts → fusion says `.candidate` → the tick enters `duckSync`
and blocks in an AppleEvent for ~600 ms → the user drags Auto-Pause off in the
pane inside that window → `apply` sets `enabled = false` (which the in-flight tick
already passed at `AutoPauseController.swift:126`) and enqueues `restore()`.

Commit `b291620` records `EXC_BAD_ACCESS` in `objc_msgSend`/`objc_release` from
`NSAppleScript` on a GCD worker thread. That was one worker thread; this is two.

**Fix:** single entry point — the adapter's serial queue owns every
`SpotifyControl` call. Have the controller call the async trio and make the
`*Sync` methods `private`, so the split cannot be reintroduced. In
`SonarEngineHost.apply`, set `enabled = false` before enqueuing the restore so the
intent is recorded before the work is queued.

### S1-5 · Generation tokens are unreachable in production

`SpotifyFadeAdapter.swift:33-34` (the claim), `:111-113` (the sync entry points),
`:123-127` (the only writer).

`nextGeneration()` is called from exactly two places: `duck(source:)` `:85` and
`restore()` `:95`. `AutoPauseController` calls only the `*Sync` variants, and
`SonarEngineHost` calls only `restore()`. So in production `_generation` increments
once per user-toggle of the Auto-Pause switch, and every guard in `duckImpl:192`,
`:195`, `restoreImpl:247`, `setVolumeSync:294`, `fade:300`, `:307`, `:310` is
trivially satisfied.

*Read and verified.* The tests that exercise supersede
(`SpotifyFadeAdapterOwnershipTests.swift:424`, `:470`) trigger it by calling
`adapter.restore()` / `adapter.duck()` from a hook — a path production never takes.
The protection is tested and absent.

**Fix:** resolve with S1-3/S1-4. Add a test asserting the controller never calls a
`*Sync` method, so the regression cannot come back.

### S1-6 · A rebuild in flight flaps the driving detector and re-logs `.tapVerified`

`AutoPauseController.swift:140-147`, `:185-199`; `TapDetector.swift:878-895`.

`tearDownTap()` correctly clears `_isCapturing`, so during the 0–2 s that
`buildTap` + `confirmAudioIsFlowing` take, `tap.isCapturing` is false and
`tapIsLive` is false. The controller then evaluates
`fusion.evaluate(poll: pollSignal, tap: nil)` — i.e. it **switches detectors
mid-episode** and credits streaks to the wrong source. Because poll cannot measure
loudness, a browser holding the output while silent can duck at that moment.
Meanwhile `tapHasAudibleSignal` is cleared and re-set on every such flap
(`:144-146`), so `.tapVerified` is re-emitted and re-logged each time; the "one log
line per episode" property the diagnostics pane depends on is lost.

`tapStatusChanged` handles `.idle` with `break` (`:196-197`) and
`AutoPauseController.stop()` never clears `tapIsUsable`, so neither is a
transition that would latch the decision.

**Fix:** latch the driving detector on a *status transition*, not a per-tick read
of a derived flag. Have `tapIsLive` updated only in `tapStatusChanged` and from a
new `onCaptureStateChange` callback, and suppress `.tapVerified` while already
verified.

### S1-7 · A wedged `AudioDeviceStop` during sleep permanently kills the tap

`TapDetector.swift:1027-1032` (sleep observers), `:878-913` (async teardown),
`:436-441` (the `tearingDown` guard).

This is new code, added during the audit, and it introduces a hard failure.
`tearDownTap()` now clears its state synchronously and moves the HAL calls to a
private `teardownQueue` that is **never waited on** — because, per the comment at
`:898-902`, a tap that never produced buffers leaves `AudioDeviceStop` wedged
inside coreaudiod and doing it inline froze the detector permanently.

`tearingDown` is cleared only in the completion block at `:907-912`. If the machine
suspends while `releaseHAL` is inside that wedged `AudioDeviceStop`, the completion
block never runs and `tearingDown` stays `true` forever. On wake, `didWake` →
`rebuildIfNeeded(force: true)` → `if tearingDown { rebuildPending = true; return }`
(`:439-441`) — and the only thing that would consume `rebuildPending` is that same
completion block. **The tap never rebuilds for the rest of the session.** There is
no log line and no UI change beyond the pane continuing to say whatever it last
said. Auto-pause silently reverts to poll-only, which per S-exec-summary-5 means
the resume stops happening.

**Fix:** give the async teardown a watchdog. Record the teardown start on the tap
queue, and if `tearingDown` is still set when `didWake` arrives (or after a
bounded timeout), clear it and rebuild anyway — a leaked aggregate is a far smaller
problem than a permanently dead detector, and `purgeStaleAggregates()` at next
launch will reap the leftover. Also: do not run the teardown at all on
`willSleep`; the wake path rebuilds regardless.

### S1-8 · `AudioActivityTracker.observe` mutates a dictionary while iterating its `keys`

`AudioActivityTracker.swift:64-65`.

```swift
for pid in pids where startedAt[pid] == nil { startedAt[pid] = Date() }
for pid in startedAt.keys where !pids.contains(pid) { startedAt[pid] = nil }
```

The second loop holds a read access to `startedAt` through the `keys` view while
performing a `mutating` subscript set on the same property. **Depends on runtime
behaviour I could not verify without building** — I am not permitted to run the
tests. It is a ported line (`THIRD-PARTY-NOTICES.md:41` says the tracking logic is
verbatim from SmartPause) and no test file references `AudioActivityTracker` at
all, so it has never been executed in this repo.

The identical pattern is repeated in `RecentSourcesModel.swift:111-113`, which *is*
reachable from a 5 s main-thread `Timer` (`RecentSourcesModel.swift:85`) and is
therefore far more likely to be hit in production.

**Fix (both):** snapshot the keys first —
`for pid in Array(startedAt.keys) where … { startedAt.removeValue(forKey: pid) }`.

### S1-9 · `run(_:)` ignores the AppleEvent error and returns the error's text

`SpotifyControl.swift:150-154`.

```swift
var error: NSDictionary?
guard let script = NSAppleScript(source: source) else { return nil }
return script.executeAndReturnError(&error).stringValue
```

`error` is written and never read (the compiler will warn). On an AppleEvent
failure the returned descriptor is the *error* descriptor and `.stringValue`
returns its message — a non-nil string. `parseState` then returns `.unknown`
(benign), but `stateAndVolume` splits on `/` (`:121`), so any error text
containing a slash yields a bogus `state` and a bogus `volume`, and
`probe.volume` non-nil feeds straight into the "did the user change the volume"
comparison at `SpotifyFadeAdapter.swift:238` and `:280`.

Commit `760e098`'s message claims the fix was to "return nil on AppleEvent error
instead of a garbage string value". **That is not what the code does.**

**Fix:** `guard error == nil, let result = script.executeAndReturnError(&error)
else { return nil }; return result.stringValue`, and treat any `errAE**`/`.number`
error as failure even when `stringValue` is empty.

### S1-10 · Unsynchronised cross-queue state in `AutoPauseController`

`AutoPauseController.swift:37` (`@unchecked Sendable`), `:59-75`, `:120-181`,
`:185-199`.

Mutated on one queue, read on another, with no lock anywhere:

| Field | Written on | Read on |
|---|---|---|
| `tapIsUsable`, `tapHasAudibleSignal` | engine queue `:140-147`; **tap queue** `:185-199` (via `onStatusChange`, `TapDetector.swift:309`) | engine queue `:140` |
| `_drivingDetector` | engine queue `:147` | **main** `SonarEngineHost.swift:166` |
| `fusion` (`:41`) | engine queue `:151`/`:153`; **main** `SonarEngineHost.swift:70-71` | main `SonarEngineHost.swift:117-123` |
| `adapter.mode` / fade durations | **main** `SonarEngineHost.swift:72-74` | engine, inside the fade loop |
| `poll.filter` | **main** `SonarEngineHost.swift:75` | **poll scan queue** `PollDetector.swift:130` |
| `tap.config` | **main** `SonarEngineHost.swift:94`, `:98`; `didSet` reads it on the tap queue `TapDetector.swift:296` | tap queue |
| `enabled` | **main** `SonarEngineHost.swift:69` | engine `:126` |

*Read and verified from the source.* `FusionState` is a `Sendable` value type,
which is exactly why this is easy to miss: the compiler is satisfied and the data
is still racy. A torn read of `fusion.loudStreakStart` (a `Date?`) is a wild date
→ a nonsense countdown in the pane.

**Fix:** make `enabled`, the fusion durations and the adapter mode one immutable
`Settings` value swapped atomically (or behind the existing lock). Replace
`drivingDetector` with an atomic. Stop reading fusion streaks from the main
thread — publish the countdown values from the engine queue instead.

### S1-11 · A denied permission produces an infinite full-tap-build retry loop

`TapDetector.swift:463-472` (`retryDelay = 5` on success; catch → `scheduleRetry`),
`:479-491` (`scheduleRetry`).

`scheduleRetry()` backs off 5 → 7.5 → 11 → 17 → 25 → 30 s and then retries **every
30 s, forever**, each attempt calling `rebuildIfNeeded(..., force: true)`. `force:
true` bypasses the `wanted == lastTargets` early return at `:444`, so a permanently
unavailable tap is rebuilt from scratch indefinitely: a Core Audio process
enumeration with an `NSRunningApplication` lookup per process
(`resolveTapTargets` `:505`), `AudioHardwareCreateProcessTap`,
`AudioHardwareCreateAggregateDevice`, `waitForAggregateReady` (up to 3 s of
`Thread.sleep`, `:795`), `startWithRetry` (up to 10 × 0.1 s), and
`confirmAudioIsFlowing` (up to 2 s, `:775`) — plus an aggregate device created and
destroyed each round.

For a *denied* permission the create call fails fast, so the loop is cheap-ish. For
a *starved aggregate* it is a multi-second blocking cycle every 30 s, indefinitely.
It also pins `retryDelay` back to 5 on any success, so a flapping tap retries
aggressively.

**Fix:** bound the retry count and require a reason to try again. Retry on
`didWake`, on a user-initiated rebuild, and when `CGPreflightScreenCaptureAccess()`
flips — not on a timer forever. At minimum, stop after N attempts and report
"tap unavailable, retrying on wake".

### S1-12 · The `.starved` diagnostic can never report the format it is naming

`TapDetector.swift:758-760` calls `confirmAudioIsFlowing()`, which on failure
calls `tearDownTap()` (`:782`) — and `tearDownTap` clears `_format` (`:893`).
The throw site then evaluates `self.format.map(Self.describe)`, which is now
always `nil`, so the message is always "no format" even when the format had just
been read back successfully from the HAL at `:723`.

Self-defeating error reporting on a path whose whole purpose is to tell the user
what is wrong. **S2.**

**Fix:** capture the format into a local before calling `confirmAudioIsFlowing()`.

---

## 2. Latency budget for the "Instant" path

### 2a. Duck path, tap driving, after the fix at `SonarEngineHost.swift:86,90`

| # | Step | Cost | Source of the number |
|---|---|---|---|
| 1 | Sound reaches the tap; IOProc measures RMS on a realtime thread, hops to the tap queue, `ingest` → `publish` | one buffer period + one `queue.async` | buffer period **unverified** — nothing reads the buffer size; `TapDetector.swift` only exposes `TapAudioFormat.frames(perBufferByteSize:)` for the log. Estimate 11 ms @ 512/48 kHz. |
| 2 | `TapSmoother.sample` | 0 | `activeDuration` is now 0 (`SonarEngineHost.swift:86`) |
| 3 | Engine tick wait for the published signal | 0–100 ms, avg 50 ms | `tickInterval = 0.1` (`AutoPauseController.swift:44,102`) |
| 4 | `FusionState` dwell | **100 ms** | `prefs.activeDuration` (`SonarEngineHost.swift:70`) |
| 5 | `control.spotifyPID()` — `NSRunningApplication` enumeration, no AppleEvent | ~1–10 ms | Foundation call, no TCC cost. **Not measured.** |
| 6 | `control.stateAndVolume()` → **2 AppleEvents** | **~600 ms** | 2 × ~300 ms (commit `321196e`); the ×2 is S1-1 |
| 7 | `control.pause()` — 1 AppleEvent | **~300 ms** | commit `321196e` |
| 8 | `settle()` — `Thread.sleep(rereadDelay)` on the engine queue, *after* the music is already paused | **200 ms** | `SpotifyFadeAdapter.swift:202,321-323`; default 0.2 at `:45` |
| | **Total** | **≈1.25 s** | of which **1.10 s is AppleScript + sleep** |

The commit `321196e` measurement "pause Spotify 0.36s after" is therefore not
reproducible from the shipped code: that figure assumes step 6 is one AppleEvent.

### 2b. Duck path, poll-only (tap unverified/unavailable)

Add up to `minScanInterval` = **0.25 s** of poll staleness
(`PollDetector.swift:101,140`); drop steps 2–3. **≈1.4 s**, all of it AppleScript
and sleep.

### 2c. Resume path, tap driving

| # | Step | Cost |
|---|---|---|
| 1 | `gapTolerance = 0.15` holds `isActive` true | 150 ms, detected at `quietCheckInterval` 0.1 s granularity → **150–250 ms** (`SonarEngineHost.swift:90`, `TapDetector.swift:43,895`) |
| 2 | Engine tick wait | 0–100 ms |
| 3 | `FusionState` quiet dwell | **300 ms** (`SonarEngineHost.swift:71`) |
| 4 | pid + `stateAndVolume()` (2 AppleEvents) | **~600 ms** |
| 5 | `control.play()` | **~300 ms** |
| 6 | `settle()` | **200 ms** |
| | **Total** | **≈1.4 s** |

Commit `b291620` measured "~1.1s at quietDuration 0.3" — consistent with 1.05 s of
engine-side cost, but that predates the poll-scan fix and excludes steps 1 and 3.

### 2d. Ordered changes, with saving and risk

| # | Change | Where | Saving | Risk |
|---|---|---|---|---|
| **1** | Make `stateAndVolume()` a protocol requirement | `SpotifyControl.swift:19-31` | **~300 ms** on duck and resume | **None.** The extension default keeps fakes compiling. Best ratio in this audit. |
| **2** | Delete `settle()` from both instant paths | `SpotifyFadeAdapter.swift:202,252` | **200 ms** on duck and resume | **Low.** In `.instant` nothing was written that needs reconciling — the sleep existed to let a value settle, and we wrote none. Drop it once #3 lands. |
| **3** | Controller uses the async trio; the adapter queue becomes the sole `SpotifyControl` caller | `AutoPauseController.swift:161,164,166` | 0 ms of latency, but removes a **1.1 s (instant) / up to 8 s (fade)** stall of the decision loop per episode | **Medium** — must ship with S1-4 and S1-5 or it trades a stall for a crash. |
| **4** | Reuse compiled `NSAppleScript` instances | `SpotifyControl.swift:150-154` | **Unknown.** `NSAppleScript(source:)` compiles on every call and these are recompiled ~10×/s while owned. Apple documents no cost; plausibly 1–20 ms each. | **Medium.** `NSAppleScript` instances are not documented thread-safe, so this is only safe *after* #3. One instance per distinct source; `setVolume(_:)` builds a per-value script, so cache by last value or switch to a raw `AECreateDesc`/`AESendMessage` event. |
| **5** | Decouple loud-streak gap tolerance from resume hysteresis | `TapDetector.swift:177-196` | **0–150 ms**, and it is the *right* shape | **Low.** Today `gapTolerance` does two jobs: it decides whether a dip resets the loud streak (`:181-183`) *and* it holds `isActive` true after the last loud sample (`:184-188`). Only the second hurts the resume. Make `isActive` decay as soon as a sample is below threshold; let `gapTolerance` govern `loudSince` only. |
| **6** | Wire `prefs.quietDuration` into the tap's decay instead of the hard-coded 0.15 | `SonarEngineHost.swift:90` | makes Instant's 0.3 s actually mean 0.3 s | **Low.** Do with #5. |
| **7** | Cache Spotify's playing state in the background so `pause` needs no probe | `SpotifyFadeAdapter.swift:173-184` | up to **~600 ms** off the duck path | **HIGH. Do not do before #1–#3.** It trades the "never resume something the user paused" contract for latency. If done at all: a background poller must own the *only* reads; `pause` may be sent optimistically only if the cached state is `.playing` **and** younger than N ms; the ownership record must carry `stateObservedAt`; `restore` must still re-probe (it already does, `:222`). Note also S1-9 — a wrong cached state currently cannot be detected at all. |
| **8** | Lower `PollDetector.minScanInterval` below 0.25 s | `PollDetector.swift:101` | 0.125 s for 0.125 s of saving, poll-only | **HIGH — recommend against.** Commit `7214ffd` measured 295 of 296 samples inside `refresh()` with Chrome playing; `AudioDetector.swift:12` claims "~14 ms" while `PollDetector.swift:89-90` says "a browser with many helpers makes it slow enough to take seconds". **Two comments in the same package contradict each other.** If you must: make it adaptive — 0.1 s while the last scan returned a non-empty process list, 1.0 s when empty. |
| **9** | Remove the duplicated dwell entirely | `FusionState.swift:40-59` | 0 ms (the tap's is already 0) | **None.** `activeDuration` is now applied once; `quietDuration` once plus the 0.15 gap. This one is already clean. |

**Realistic target after #1, #2, #3, #5:** duck ≈ 0.01 + 0.05 + 0.10 + 0.30 + 0.30
≈ **0.76 s**; resume ≈ 0.15 + 0.05 + 0.30 + 0.30 ≈ **0.80 s**.

Getting under 0.5 s on this machine is not possible while the pause itself is a
300 ms AppleEvent, unless the probe is removed (#7) or the transport is replaced
with a direct `AESendMessage` to Spotify rather than a compiled script. **That is
the real recommendation**: the latter also retires the `b291620` crash history at
the same time.

---

## 3. Detector correctness

### 3a. Is tap-over-poll right? Yes, and the reasoning is sound

`AutoPauseController.swift:136-154`. Poll cannot measure loudness; letting it veto
or extend a tap decision reintroduces exactly the bug commit `07bfacb` fixed (poll
reading silence as loud and therefore never resuming). The three-tier gate —
`isCapturing` for buffers, `TapSmoother` for loudness, `FusionState` for dwell — is
the right decomposition. **No finding.**

### 3b. The tap-exists-but-has-not-yet-proven window

`AutoPauseController.swift:140`; `TapDetector.swift:383-347`, `:775-793`, `:924`.

Between `AudioDeviceStart` returning `noErr` and the first `handleAudioBlock`,
`tap.isCapturing` is false so poll drives — correct. The status handling is also
correct now: `.active` is not published until `confirmAudioIsFlowing()` succeeds
(`:758-761`), so `.active` already implies buffers arrived, and
`tapIsOperational` (`SonarEngineHost.swift:36-42`) double-checks. Good.

**One weakening worth naming.** The gate is `isCapturing`, i.e. "a buffer arrived",
not "a buffer contained sound". The previous version used
`tapSignal?.rms > 0.0001`. A tap delivering a clean stream of digital silence is
now "verified". `TapDetector.lastPeak` (`:400-404`) exists precisely to answer the
stronger question and **the controller never reads it**. The field name
`tapHasAudibleSignal` (`AutoPauseController.swift:70`) and the pane's "Tap
capturing (loudness detection)" (`SonarEngineHost.swift:155`) both overclaim.

**Fix:** `let tapIsLive = tapIsUsable && (tap?.isCapturing ?? false) && (tap?.lastPeak ?? 0) > 0`,
and rename the field to `tapHasBuffers`.

### 3c. Is 0.1 s / 0.3 s achievable, and does gap tolerance fight short bursts?

`SonarEngineHost.swift:86,90`; `TapDetector.swift:177-196`; `FusionState.swift:40-59`.

After the fix the dwell is applied once, so 0.1 s is achievable **up to tick
granularity**: `activeDuration = 0.1` with a 0.1 s tick means the candidate fires
on the *second* tick after the streak starts, so the real floor is 0.1–0.2 s. The
slider range is `0...5` step `0.1` (`AutoPausePreferencesModel.swift:11-12`), so
0.1 is the smallest non-zero the user can pick; dragging to 0 gives
`FusionState`'s documented "react to the very first sample"
(`FusionTests.swift:45-51`).

**Gap tolerance vs short bursts — benign now, for a non-obvious reason.** With
`activeDuration = 0`, `gapTolerance` no longer affects *whether* a burst triggers
(the first above-threshold sample already activates). It only affects *decay*:
- A 0.3 s notification chime activates immediately, holds 0.15 s, decays, fusion
  waits 0.3 s, restores. **The user's music stops for ~0.5 s for a chime.** This is
  a product decision, not a bug — but it is new behaviour introduced by setting
  `activeDuration = 0`, and it is worth an explicit choice.
- Conversely a gap shorter than `gapTolerance` between two loud samples is bridged,
  which is what you want for speech.

The remaining latency floor is exactly 0.15 + 0.3 = 0.45 s before any AppleEvent.
See §2d #5/#6.

### 3d. Does the engine ignore its own process?

`PollDetector.swift:53-59` (pid, responsible pid, raw and responsible bundle,
daemon names); `TapDetector.swift:505-534` (object IDs excluded by `getpid()`, by
bundle, by daemon name). This is thorough and correctly covers helpers via the
responsible pid. `PollRulesTests.swift:29-90` pins each rule individually.
**No finding.**

One gap: the tap resolves targets **once per build** (`:443`), so a process object
that appears later is not excluded for up to `rebuildDebounce` = 2 s plus build
time. A notification sound in that window is captured. **S3.**

### 3e. A browser that keeps the output open while silent

`AudioDetector.swift:60-83` reads only `kAudioProcessPropertyIsRunningOutput`.
`AudioActivityTracker.swift:15-19` documents the upstream finding verbatim: "apps
usually keep the stream open when paused", and `IsRunningOutput` produces no
notifications at all. Commit `5d7e621` proves it: 45 s of digital silence still
produced "candidate: poll".

**This is the most consequential known limitation and it is not handled anywhere.**
Consequences: (1) a silent browser pauses the music; (2) the resume never arrives,
so the music stays paused indefinitely. See F1.

---

## 4. Failure modes

| # | Scenario | What the user experiences | What the code does | Music left wrong? |
|---|---|---|---|---|
| **F1** | **Screen & System Audio Recording denied or revoked; or the aggregate is starved; or no default output device** | Another app makes a sound, Spotify pauses — and never comes back, because poll keeps reporting "loud" for an app that is now silent. | `buildTap` throws → `.unavailable` → `tapIsUsable = false` (`AutoPauseController.swift:187-190`) → poll-only. Pane says "Tap unavailable (poll-only)" (`SonarEngineHost.swift:191-193`). | **YES — indefinitely.** Worst outcome in the product; nothing guards it. |
| **F2** | **Automation denied or revoked while running** | Nothing happens, ever, and nothing explains it. | `run` returns nil → `stateAndVolume` → `(nil,nil)` → `probe.state != .playing` → `.skippedNotPlaying` (`SpotifyFadeAdapter.swift:178-183`) emitted **every tick** (10/s). `SonarEngineHost.swift:149-150` sets the label but writes **no log line**. | No (nothing is touched), but indistinguishable from "the user paused Spotify". **S2: a fully broken feature leaves no evidence.** |
| **F3** | No default output device | Auto-pause silently degrades to poll; a multi-second stall on the tap queue on every rebuild. | `defaultOutputDeviceUID()` returns nil → `description.deviceUID`/`stream` never set (`TapDetector.swift:659-661`), which the comment at `:655-658` says yields silence on this OS. The tap is then built in the known-broken configuration and reported as "delivered no buffers" — a reason that blames buffers rather than the missing device. | No, but the diagnosis is wrong. **S2.** Fix: refuse to build a tap when there is no default output and say so. |
| **F4** | **Output device changed while ducked (AirPods connect/disconnect, dock, monitor)** | The tap keeps measuring the old device. Auto-pause is either dead or reading the wrong output; if the sample rate changes, the RMS is over a format nobody re-read. | `kAudioHardwarePropertyDevices` listener → `rebuildIfNeeded(reason: "device change")` → `resolveTapTargets()` (`:443`) which depends **only on the process list**, so `wanted == lastTargets` → **early return at `:444`, no rebuild**. The device UID is not part of `TapTargets` (`:497-503`). | Potentially — the duck is decided from a stale stream, and recovery only happens if some *process* change later alters the targets. **S1.** Fix: add the resolved `defaultOutputDeviceUID()` to `TapTargets` so a device change is a target change. |
| **F5** | Spotify restarts / auto-updates while ducked | Usually correct, one silent hole. | `reconcileImpl:266-268` relinquishes on pid change and `restoreImpl:214-221` refuses to `play` a new instance. **But reconcile only runs on a `.hold` tick** (`AutoPauseController.swift:165-166`) and fusion is in `.candidate` for the whole loud episode — so during the episode the adapter still believes it owns a dead pid, and if Spotify comes back **playing** it is never re-paused for the rest of the episode. | No, but a duck is silently lost. **S3.** |
| **F6** | Spotify not running | Nothing happens, no message. | `duckImpl:173` returns with no ownership and **no event**. `SonarPermissions.swift:243` *does* distinguish `procNotFound` → `.targetNotRunning` for the permission row, so the pane holds two contradictory truths. **S3.** |
| **F7** | **User pauses Spotify by hand mid-duck** | When the other app goes quiet, Spotify starts playing again. The user paused it. They did not ask for that. | Undetectable from the outside: `player state` is `paused` whether we paused it or the user did. `reconcileImpl:274` only relinquishes on observing `.playing`. `duckInProgress` (`:149-159`) only guards the fade window. The case "user pauses and leaves it paused" reaches `restoreImpl:235` → `.paused` → `control.play()` at `:251`. | **YES — we resume something we did not pause.** The contract at `:30-32` claims this cannot happen. **S1 by the task's own definition.** To be explicit: this one is a genuine *ambiguity*, not a coding mistake. A partial mitigation exists — reconcile already catches "user paused then played". The uncovered case is "user paused and left it". A cheap improvement is to record the track position at duck time and refuse to `play` if it advanced, i.e. evidence the user acted. Not clean, but better than nothing. |
| **F8** | System sounds, notification chimes, calls | Every chat client, every notification, every ringtone pauses the music. | `systemsoundserverd` and `usernoted` are excluded by name (`PollDetector.swift:45-48`, `TapDetector.swift` resolve) — but the tap's exclusion list is baked into the `CATapDescription` at build time, so a new system-sound process is excluded only after a rebuild (2 s debounce + build). Third-party alert sounds are **not** excluded and are not meant to be. | No. But with `activeDuration = 0` the instant preset now pauses for a single Mail ping where it previously would not. **S2 product decision, worth an explicit choice.** |
| **F9** | Force-quit / crash of Sonar | A stale aggregate device in Audio MIDI Setup. | `purgeStaleAggregates()` at `AutoPauseController.swift:97`, on the **main thread at launch**. There is **no** `applicationWillTerminate → controller.stop()` (`AppDelegate.swift:97-100` only removes the event monitor). The aggregate is created private (`TapDetector.swift:703`) with the comment at `:691-692` "never appears in Audio MIDI Setup and is reaped by coreaudiod when the process exits" — which **directly contradicts** `purgeStaleAggregates`'s own doc at `:222-228` ("never goes away on its own — during development seven accumulated"). One of the two is now false. **Could not verify which without hardware.** | No. **S2: a comment that now lies, in both directions.** |
| **F10** | Grant revoked in System Settings while the pane is closed | Nothing is re-checked; the engine keeps ducking on stale assumptions. | `SonarPermissions.startLiveUpdates` is only called from the pane's `.onAppear` (`AutoPausePreferencesView.swift:133`) and stopped on `.onDisappear`. There is no notification for a TCC change (the contract says so at `:127-129`). | Depends. **S3.** |
| **F11** | Second Sonar instance running | Both duck and both restore; they fight. | Excluded by bundle on both paths, so neither hears the other — but both will pause/resume the same Spotify. | Two resumes possible. **S3**, untested. |

---

## 5. Test gaps, ranked by risk

`AutoPauseController` is **never tested with a tap**. Every controller test uses
`tap: nil` (`ControllerTickTests.swift:36`, `PresetAndThrottleTests.swift:71,87`).
So `tapIsUsable`, `isCapturing`, `tapStatusChanged`, `drivingDetector`, the
poll-suppression rule, and the whole S1-6 flap are untested.

| Rank | Missing test | Why it matters | Hardware? |
|---|---|---|---|
| 1 | `controllerPrefersTheTapAndIgnoresPollOnceCapturing` — tick with a scripted `isCapturing = true` tap carrying `rms < threshold` while poll says active; assert `drivingDetector == .tap` and that the decision follows the tap | The load-bearing rule of the whole engine (commit `07bfacb`) has zero coverage | No |
| 2 | `controllerFallsBackToPollWhenTheTapCapturesOnlySilence` — `isCapturing = true`, `lastPeak == 0`; assert `drivingDetector == .poll` | Pins §3b, and fails today | No |
| 3 | `controllerDoesNotLeaveAFrozenTapSignalAcrossARebuild` — verify, then tear down, then tick | S1-6 | No |
| 4 | `duckInInstantModeDoesNotWriteTheVolumeOnAManualResume` (flip the existing `_KNOWNBUG` test) | S1-2, the module's headline contract | No |
| 5 | `theEngineQueueNeverCallsTheSpotifyControl` — a `SpotifyControl` fake that records the thread; tick a controller with an adapter | S1-3/S1-4/S1-5 all reduce to this | No |
| 6 | `recentSourcesPruneExpiredEntries` / `activityTrackerPrunesWithoutTrapping` | S1-8; the `RecentSourcesModel` one is reachable from a main-thread `Timer` | No |
| 7 | `stateAndVolumeReturnsNilWhenTheAppleEventFails` | S1-9; `run(_:)` is not injectable today | No, with a small seam |
| 8 | `tapTargetsChangeWhenTheDefaultOutputDeviceChanges` — a pure function over `(objectIDs, outputUID)` | F4; the only F4 fix testable without a device | Partly — needs `resolveTapTargets` split from the Core Audio calls |
| 9 | `aDuckDoesNotBlockTheEngineTick` — a `SpotifyControl` fake whose `pause()` blocks on a semaphore; assert the next detector tick still returns | The fade stall; the regression test that makes the async move permanent | No |
| 10 | `aWedgedTeardownDoesNotDisableTheTapForever` — drive `didWake` with `tearingDown == true` and assert a rebuild is still scheduled | S1-7, the newest and most severe finding | No, if the sleep observers are factored into an injectable seam |

**All ten can be tested without hardware.** #7 and #8 each need one small refactor.

Below the top 10, in order: `TapDetector.buildTap` failure paths (unreachable
without a device — `tapStartStopSmoke` at `TapDetectorTests.swift:85` is gated on
`SONAR_TAP_SMOKE=1` and asserts almost nothing); `purgeStaleAggregates` idemence;
`AudioActivityTracker` (no test file at all); `PollDetector` staleness bounds
(`pollRefreshDoesNotBlockOnASlowScan` passes trivially because `refresh` only
enqueues — it never asserts a *correct* signal eventually lands);
`AppleScriptSpotifyControl.stateAndVolume` parsing of odd replies;
`SonarEngineHost.apply` writing **every** field the preferences model owns into the
engine — a test there would have caught the 1.0 s tap-dwell latency finding, and
`gapTolerance`/`quietCheckInterval` are currently unowned magic numbers with no
test pinning them.

---

## 6. Dead weight, duplication, and comments that now lie

1. **`ActivationTracker` is 100% dead.** `AudioActivityTracker.swift:118-139`.
   Nothing references it anywhere in `Sonar/` or `Packages/`, not even its own
   `shared` static. It also has a thread-safety bug if it were ever used:
   `start()` writes `lastActivated` (`:126`) on the caller's thread while the
   observer writes it on `.main` (`:132-134`), and `lastActivation(pid:)` reads it
   with no lock (`:138`). **Delete it.**
2. **`AudioActivityTracker` is functionally dead.** `:20-114`. It is instantiated
   by `PollDetector` (`:80`), `start()` registers a Core Audio listener on the
   system process list and enumerates every process object (`:68-83`), and
   `activeSources()` feeds it `observe(playing:)` (`PollDetector.swift:130`) — but
   the only reader, `startTime(pid:)` (`:53`), has **no callers**, and
   `onActivityChange` (`:27`) and `logHandler` (`:29`) are never assigned, so every
   `log(...)` call (`:41-43`, `:75`, `:80`, `:99`, `:104`) is a no-op. It costs a
   live Core Audio property listener and a per-change enumeration for nothing, and
   it carries the S1-8 dictionary trap. **Delete it and `observe()` with it.**
3. **`AudioActivityTracker` never removes its listener blocks.** `:76-81` adds a
   block per process object; `AudioObjectRemovePropertyListenerBlock` is never
   called and `watched` (`:24`) only grows. Unbounded growth over a long session.
   Moot if #2 is done.
4. **`SpotifyFadeAdapter.duck(source:)` and `.reconcile()` have no production
   callers.** `:84-91`, `:104-108`. Only `restore()` is called
   (`SonarEngineHost.swift:102`). The `*Sync` trio is the entire live surface. See
   S1-5.
5. **`TapDetector.lastPeak` and `TapDetector.format` have no production callers.**
   `:400-404`, `:351-355`. `lastPeak` is the exact signal the controller's trust
   gate should use and does not (§3b); `format` reaches only `onDiagnostic`. Either
   wire them or drop them from the contract.
6. **`AudioDetector.runningOutputProcesses` resolves `NSRunningApplication` twice
   per process.** `:72-74`. Cache it in one local. This is the function commit
   `7214ffd` profiled at 295/296 samples.
7. **Two independent Core Audio process scans.** `PollDetector.performScan` at 4 Hz
   (`PollDetector.swift:101,159`) *and* `RecentSourcesModel.refresh()` on a 5 s
   **main-thread** `Timer` (`RecentSourcesModel.swift:85,95-117`). The second calls
   the same function the commit measured as pathologically slow, on the main
   thread. It will freeze the menu bar whenever a browser holds many audio
   helpers. **S2.** Share one scan.
8. **Comments that assert something a later fix made false** — collected because
   they actively mislead the next reader:
   - `AudioDetector.swift:12` — "A single scan costs ~14 ms" — vs
     `PollDetector.swift:89-90` "a browser with many helpers makes it slow enough
     to take seconds" — vs commit `7214ffd`'s 295/296 samples. Three claims, one
     function.
   - `TapDetector.swift:222-228` vs `:691-692` — private aggregates "never appear
     in Audio MIDI Setup and are reaped by coreaudiod" vs `purgeStaleAggregates`
     existing because they "never go away on their own". Mutually exclusive.
   - `TapDetector.swift:225-228` — "sweep anything with our name that is **not**
     the one we are about to create". The code has no such exclusion; it destroys
     every match (`:244-260`).
   - `TapDetector.swift:695-698` — "A fixed UID means a crashed or killed run
     leaves a stale aggregate registered system-wide" — true, but moot if private
     aggregates are reaped on exit.
   - `HybridDetector.swift:24-25` — "Full implementations land in tasks 5 … and
     6 …". Both landed many commits ago.
   - `FusionState.swift:61` — `reset()` is documented for "mode change,
     enable/disable, sleep/wake". Nothing calls it for any of those three:
     `AutoPauseController.stop()` is the only caller and the app never calls
     `stop()`.
   - `SpotifyFadeAdapter.swift:26-28` — "All control calls happen on one private
     serial queue (never main)". They happen on the engine's serial queue. See
     S1-4.
   - `SpotifyFadeAdapter.swift:174-176` — "One AppleEvent instead of two". It is
     two. See S1-1.
   - `SpotifyFadeAdapter.swift:31-32` — "any manual pause/volume change …
     relinquishes ownership (volume is preserved, never clobbered)". Violated in
     instant mode (S1-2) and for a hand-pause (F7).
   - `AppDelegate.swift:81-82` — "Starts on the engine's own queues".
     `controller.start()` calls `purgeStaleAggregates()` and
     `poll.start() → performScan()` **synchronously on the main thread**.
   - Commit `760e098`'s "return nil on AppleEvent error instead of a garbage string
     value" — not implemented. See S1-9.
   - `TapDetector.swift:918-921` — "a realtime callback must not take a lock
     another thread can hold", while `:925-926` does exactly that (`self.format`
     takes `lock`; `callbackLock` is taken too). **The RT thread still takes two
     locks per audio block.** An IOProc that blocks can glitch the output the tap
     aggregate is clocking. **S2.** Make the RT path lock-free: an atomic counter
     and an atomic format snapshot taken at build time.
   - `TapDetector.swift:437-441` — "Never build on top of a device that is still
     being torn down: the ids can be recycled by the HAL" — a real hazard, and
     `purgeStaleAggregates()` at `AutoPauseController.swift:97` can still destroy an
     aggregate that coreaudiod is mid-way through releasing. The guard covers only
     the detector's own teardown, not the startup sweep. **S3.**
9. **`AutoPauseController.poll.refresh()` runs 10×/s and its result is discarded
   whenever the tap is live** (`:136` vs `:151`). The comment at `:127-135`
   justifies it as feeding the diagnostics UI. Fine, but note #7 — the same data
   is already being collected by `RecentSourcesModel`.
10. **`AutoPausePreferencesView.drivingDetectorText` still uses
    `host.tapIsOperational`** even though `SonarEngineHost` now publishes the
    authoritative `drivingDetector` (`SonarEngineHost.swift:30,166`). A one-line
    simplification that also removes the last S1-6-style divergence.
11. **`AutoPausePreferencesModel.presetThreshold` is stale — and this one is user
    visible in the new code.** `AutoPausePreset.instant.threshold` is 0.01 and
    `fade` is 0.02 (`AutoPausePreset.swift:78-83`), but the model still applies a
    single `presetThreshold: Double = 0.02` to *both* presets
    (`AutoPausePreferencesModel.swift:155`) and matches against it (`:165`). So
    picking "Instant" writes a threshold that `currentPreset` then reports as
    **"Custom"**, and the pane's "Reset to Instant" button never lights up.
    The model's own comment at `:36-38` says "`AutoPausePreset` grows its own
    `threshold`; the pane matches against this" — it grew, and the pane did not
    follow. **Fix:** `threshold = Double(preset.threshold)` and match against
    `preset.threshold`.

---

## 7. What each agent should do with this

**agent-engine** (owns the 12 engine files + `SonarEngineHost.swift`) — the owner of
S1-1 through S1-12 and §2d. Shortest path to the biggest win: S1-1 (one line) and
S1-2. S1-3/S1-4/S1-5 must ship together. S1-7 and S1-11 are in code that landed
*during* this audit, so re-read those sections against your current file.

**agent-ui** (owns `AutoPausePreferencesModel.swift`, `AutoPausePreferencesView.swift`,
`SonarPermissions.swift`, `RecentSourcesModel.swift`, `SonarLog.swift`) — §6 item 11
is yours and is a live UI bug in the new preset code. §6 item 7 (`RecentSourcesModel`
scanning Core Audio on the main thread every 5 s) and §6 item 10 are yours. F2, F3,
F6 and F10 are the user-visible failure modes in your files. `SonarPermissions` is
good — I found no correctness bug in it; F10 is a "nobody calls this when the pane
is closed" gap, not a bug in the class.

**agent-tests** (owns the test target) — §5 is your backlog. The single most
valuable thing you can add is rank 1 + rank 5: together they pin the load-bearing
detector rule and the threading contract, which is where every S1 finding lives.
Note that three test files you own currently *document bugs as expected behaviour*
with `_KNOWNBUG` suffixes (`SpotifyFadeAdapterOwnershipTests.swift:330`, `:396`,
`:560`) — those are the right tests to flip once the fixes land.

**agent-e2e** (owns the scripts) — §2d is where the latency numbers to assert live.
`scripts/autopause-smoke.sh` is the natural home for a "pause within N seconds"
assertion; use the Instant preset numbers in §2a as the current baseline and the
§2d target as the goal. F4 (AirPods / output device change) and F7 (hand-pause
mid-duck) are the two failure modes worth a scripted pass each — both need real
hardware and are not reachable from unit tests.

**Whoever commits this work:** the engine was mid-rewrite throughout, so verify the
tree builds and the full test suite passes before staging. Do not stage this file
together with someone else's half-finished work — it is documentation and can go in
on its own.

---

## 8. Statement of changes

**The auditor changed nothing in the repository.** This was a strictly read-only
task: file reads, content search, `git log` / `git show` / `git status`, and
`stat`/`shasum` on files the auditor did not write. No edit, create, delete,
build, install, run, commit or push; no TCC change; Sonar and Spotify were not
launched or quit; audio was not touched. No `swift test` or `xcodebuild` was run,
which is why the runtime-dependent claims (S1-8, F4, F9, and the `setVolume` cost
in §2d) are labelled as unverified.

The only file written by this session is `docs/AUTOPAUSE-ENGINE-AUDIT.md` (this
file), plus a pointer to it appended to `docs/PARALLEL-WORK-CONTRACT.md`. Nothing
under `Packages/` or `Sonar/` was touched.
