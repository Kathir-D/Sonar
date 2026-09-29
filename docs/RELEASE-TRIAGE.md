# Release triage — Auto-Pause engine, v0.1.0

- **Author:** agent-triage
- **Date:** 2026-09-28
- **Scope:** every finding in [`AUTOPAUSE-ENGINE-AUDIT.md`](AUTOPAUSE-ENGINE-AUDIT.md), re-derived
  against the current tree (the audit was pinned to `2e6bf0a`; the engine has been rewritten since).
  Six findings from that audit's own "fixed while the audit was running" table were not
  re-investigated.
- **Files changed:** `Packages/AutoPauseEngine/Sources/AutoPauseEngine/` only (7 files), plus this
  document. Nothing under `Sonar/`, `Tests/`, `scripts/`, `Package.swift`.
- **Verification:** `swift build` clean, no new warnings (one pre-existing warning removed).
  `swift test` 272/272 green, same as before the changes — no test needed updating.

Classification key: **BLOCKER** = a 0.1.0 user hits it and it is visible or damaging.
**SHOULD FIX NOW** = real and cheap, and this is the release everyone sees first.
**LATER** = real, not worth the risk of changing now. **ALREADY FIXED** / **WRONG** = the audit is
out of date or mistaken, with evidence.

---

## 1. Triage table

### 1a. Correctness bugs (§1)

| # | Short name | Class | Evidence (current tree) |
|---|---|---|---|
| S1-1 | Batched state+volume read unreachable | **ALREADY FIXED** | `SpotifyControl.swift:42` is a protocol *requirement*; `:48` keeps the two-read default for fakes; `:126` is the one-round-trip override, now reachable. |
| S1-2 | Instant mode overwrites a user volume | **ALREADY FIXED** | `SpotifyFadeAdapter.swift:402` records `setDuckedVolume(probe.volume)` in `.instant`, so `restoreVolumeIfUntouched` (`:535`) has both operands and skips the write when the user moved the slider. |
| S1-3 | Engine loop blocks for the whole fade | **ALREADY FIXED** (production) | `AutoPauseController.swift:251-256` dispatches on `adapterDispatch`; `SonarEngineHost.swift:69` sets `.onAdapterQueue`, so `fade()` (`:549`) runs on `sonar.spotify-fade`, not the 10 Hz queue. Residual: the `*Sync` trio is still `public`, so nothing *stops* the split returning. |
| S1-4 | Two threads inside `NSAppleScript` | **ALREADY FIXED** | Every production entry point (`AutoPauseController` duck/restore/reconcile, `SonarEngineHost.apply:119`) is async on the adapter queue; the only `SpotifyControl` calls are inside `queue.async` blocks. Same residual as S1-3. |
| S1-5 | Generation tokens unreachable | **ALREADY FIXED** | `duck(source:)` `:136` and `restore()` `:148` bump the token, and both are what the controller calls in production. The generation guards at `:389/:468/:544` are live again. |
| S1-6 | Rebuild flap: detector switch + repeated `.tapVerified` | **SHOULD FIX NOW → FIXED** | `AutoPauseController.swift:218` (new `tap?.isRebuilding` read), `:231` (`.hold` instead of poll), `:222` (verified flag survives a rebuild). `TapDetector.swift:498`. |
| S1-7 | Wedged `AudioDeviceStop` kills the tap for the session | **BLOCKER → FIXED** | `TapDetector.swift:569-596`: the `tearingDown` guard now times out against `teardownStartedAt`/`teardownWatchdog` (`:637`) and builds anyway instead of parking `rebuildPending` forever. |
| S1-8 | Mutating a dictionary while iterating its `keys` | **WRONG (the crash claim) / fixed anyway** | The `keys` view retains the storage, so the first write copies and the loop walks a different dictionary: wrong-by-accident, not a trap. One line, `AudioActivityTracker.swift:69`, so the per-scan copy goes away and the next reader is not misled. The identical line in `RecentSourcesModel.swift:111` is still live — see §5. |
| S1-9 | `run(_:)` ignores the AppleEvent error | **SHOULD FIX NOW → FIXED** | `SpotifyControl.swift:167-175` now returns nil when `error != nil` instead of the error message's `.stringValue`. |
| S1-10 | Unsynchronised cross-queue state | **LATER** | Still true (`enabled`, `fusion`, `adapter.mode` written on main, read on the engine/adapter queues). Bounded impact: every field is a single word (`Bool`, `Double`, `Date`, an enum payload), so there is no torn value to act on — the worst observable is a wrong countdown in the pane. The proper fix is the `Settings`-value refactor the audit proposes, which is exactly the kind of change that breaks things at 0.1.0. New `TapDetector.isRebuilding` *is* lock-protected (`TapDetector.swift:498-508`). |
| S1-11 | Infinite full-build retry loop | **SHOULD FIX NOW → FIXED** | `TapDetector.swift:645-654`: capped at 120 attempts (delay saturates at 30 s, so ~1 h) with a log line. Wake, rules changes and a successful build all reset it. Sized so the cap cannot bite a user who grants the permission late — see the reasoning at `:340-352` (comment above `retryAttempts`). |
| S1-12 | `.starved` can never report the format | **SHOULD FIX NOW → FIXED** | `TapDetector.swift:995-1000`: the format is captured into a local before `confirmAudioIsFlowing()` tears the tap down and clears it. |

### 1b. Latency budget (§2)

| # | Item | Class | Note |
|---|---|---|---|
| §2a–2c | The three latency tables | **INFORMATIONAL, partially stale** | S1-1 removed one of the two AppleEvents from both the duck and the resume, so the "≈1.25 s duck / ≈1.4 s resume" totals are each roughly 300 ms pessimistic. Not re-measured — that needs hardware and the designated test runner. |
| §2d #1 | `stateAndVolume` requirement | **DONE** | See S1-1. |
| §2d #2 | Delete `settle()` from both instant paths | **LATER, and the claim is wrong** | The sleep is *after* `pause()`/`play()` have returned, so removing it saves no user-visible latency — it only frees the adapter queue for 200 ms. `SpotifyFadeAdapter.swift:406/:491`. |
| §2d #3 | Async trio | **DONE** | See S1-3/4/5. |
| §2d #4 | Reuse compiled `NSAppleScript` | **LATER** | Real, unknown payoff, and it makes the adapter the sole owner of long-lived script objects. Not this release. |
| §2d #5/#6 | `gapTolerance` doing two jobs; `quietDuration` not wired to the tap decay | **LATER** | A feel change, not a defect. #6 lives in `SonarEngineHost.swift:99` (not mine) — see §5. |
| §2d #7 | Cache Spotify state to skip the probe | **NO — recommend against** | Trades the never-resume-something-the-user-paused contract for ~600 ms. Not at 0.1.0. |
| §2d #8 | Lower `PollDetector.minScanInterval` | **NO — recommend against** | Agrees with the audit: the scan is the function the profiling commit caught 295/296 times inside. |
| §2d #9 | Duplicated dwell | **NO FINDING** | Agreed, already clean. |

### 1c. Detector correctness (§3)

| # | Item | Class | Note |
|---|---|---|---|
| 3a | Tap over poll | **NO FINDING** | Agreed, and the code now implements it. |
| 3b | `isCapturing` vs "a buffer contained sound" | **WRONG — do not apply the proposed fix** | The audit's `&& lastPeak > 0` would make a *healthy tap in a silent room* report `drivingDetector == .poll`, so the pane would say "Sonar cannot tell silence from sound" for a tap that is working perfectly, and it would hand the vote to poll — which reads a paused browser as loud. That is worse than the weakness it fixes. `_lastPeak` is monotonic and zeroed only by a teardown, so it can never distinguish "silent room" from "broken tap". The real cause of a silent-but-capturing tap is now a hard build failure instead (F3, below). The only defect left is the field *name* `tapHasAudibleSignal` — cosmetic, LATER. |
| 3c | Gap tolerance vs short bursts | **LATER — product decision** | A 0.3 s chime pausing the music for ~0.5 s follows from `activeDuration = 0`; that is a choice, not a bug. |
| 3d | Targets resolved once per build | **HALF FIXED, half LATER** | The output-device half is F4 below. A process that appears *after* the build is still not excluded for up to 2 s + build time: LATER (S3). |

### 1d. Failure modes (§4)

| # | Scenario | Class | Evidence / action |
|---|---|---|---|
| F1 | Tap unavailable → poll-only → a silent app pauses and the resume never comes | **REAL, NOT FIXABLE IN CODE — top release risk** | See §3 of this document. Inherent to `IsRunningOutput`; no timeout can fix it without breaking long videos. |
| F2 | Automation denied/revoked: silent no-op | **SHOULD FIX NOW → HALF FIXED** | `run(_:)` now returns nil, so the failure is "cannot talk to Spotify" instead of a half-parsed error string that fed the volume comparison. The missing log line for `.skippedNotPlaying` is `SonarEngineHost.swift:166` — not mine, see §5. |
| F3 | No default output device | **BLOCKER → FIXED (see N1 below)** | The audit called this "wrong diagnosis, S2". The consequence is much worse than wrong wording, and it is now a hard build failure. |
| F4 | Output device changed while ducked | **BLOCKER → FIXED** | `TapDetector.swift:684/692/731/747`: `outputDeviceUID` is part of `TapTargets`, so a device change is a target change and the tap re-binds to the new default output. Before: `wanted == lastTargets` → early return → the tap kept measuring an output that no longer existed, forever. |
| F5 | Spotify restarts while ducked | **ALREADY FIXED** | Reconcile runs on every owned tick (`AutoPauseController.swift:251`), not only on `.hold`, so a dead pid is noticed within `reconcileInterval`. |
| F6 | Spotify not running: no event at all | **LATER** | `duckImpl` returns silently. Contradicts the pane's `procNotFound` state, but the fix is in the app layer. |
| F7 | User pauses Spotify by hand mid-duck → engine resumes it | **LATER — genuine ambiguity** | `player state` is `paused` whether we paused it or the user did; `restoreImpl`'s `.paused` → `play()` cannot tell. The audit's track-position probe is the only cheap-ish idea and it is not clean. Unchanged. |
| F8 | Chimes/ringtones pause the music | **LATER — product decision** | Follows from `activeDuration = 0`. |
| F9 | Force quit leaves a stale aggregate | **ALREADY FIXED (the comment contradiction at least)** | `TapDetector.swift:222-234` now says the right thing: only *public* aggregates are swept, the current one is private and is reaped by coreaudiod. The audit's "it destroys every match" bullet is also stale — `:264` skips private aggregates. Nothing to purge any more. What is still missing is `applicationWillTerminate → controller.stop()`, which is the app layer's file; it no longer matters for music state because of N2. |
| F10 | Grant revoked while the pane is closed | **LATER** | No TCC notification exists; this is the app layer's `SonarPermissions`. The engine side is now correct either way: revocation degrades to poll-only loudly. |
| F11 | Two Sonar instances | **LATER, untested** | Unchanged. |

### 1e. Dead weight and comments (§6)

| # | Item | Class |
|---|---|---|
| 6.1 | `ActivationTracker` is 100% dead | **LATER** — deleting public API this close to a release buys nothing |
| 6.2 | `AudioActivityTracker` is functionally dead (only `startTime(pid:)` reads it; no callers) | **LATER** — but note it costs a live Core Audio property listener and an `NSRunningApplication` resolution per process per scan. It is the single biggest known waste in the package. |
| 6.3 | It never removes its listener blocks | **LATER** — `watched` only grows; moot if 6.2 is done |
| 6.4 | `duck(source:)`/`reconcile()` had no production callers | **ALREADY FIXED** — both are the production path now |
| 6.5 | `lastPeak` has no production caller | **WRONG** — see 3b above; the audit's proposed use is harmful |
| 6.6 | `runningOutputProcesses` resolves `NSRunningApplication` twice | **LATER** — 2 lines, but it is on a background queue now and off the engine's critical path |
| 6.7 | Two independent Core Audio process scans, one on a 5 s **main-thread** timer | **NOT MINE — see §5.** This is the more likely UI freeze, not the engine's. |
| 6.8 | Comments that now lie | **MOSTLY FIXED upstream.** Stale bullets: the `purgeStaleAggregates` contradiction, "sweep anything *not* the one we are about to create", and "a fixed UID leaves a stale aggregate" are all already resolved in the current code. I fixed the one that was still a live trap: `TapDetector.swift:1173` claimed a realtime callback takes no lock while taking two — rewritten to state what it really does and what the real fix would be. `AudioDetector.swift:10-16` ("~14 ms") now agrees with `PollDetector`. `HybridDetector.swift:24-25` ("implementations land in tasks 5 and 6") is still stale — LATER, cosmetic. |
| 6.9 | `poll.refresh()` 10×/s, discarded when the tap is live | **NO FINDING** — the diagnostics need it |
| 6.10 | Pane uses `tapIsOperational` instead of `drivingDetector` | **NOT MINE — see §5** |
| 6.11 | `presetThreshold` stale in the pane | **NOT MINE — see §5** |

### 1f. Test gaps (§5)

All ten are the tests agent's backlog. None of the 272 existing tests changed behaviour because of
my work (verified by running the suite before and after), and the two parked behind `#if TAP_FAKES`
still do not compile because `TapSignalSource` still does not exist — my `isRebuilding` addition
does not create that seam. Three points of substance:

- **Rank 2** asks for `controllerFallsBackToPollWhenTheTapCapturesOnlySilence` (`isCapturing == true`,
  `lastPeak == 0` → `drivingDetector == .poll`). **Do not write that test.** It would pin the
  behaviour §1c/3b argues is harmful: a correctly working tap in a silent room has exactly those
  two values, and the assertion would say the app must distrust it. The existing file already pins
  the opposite, and correctly (`ControllerDetectorPreferenceTests.swift:99-131`).
- **Rank 5** (`theEngineQueueNeverCallsTheSpotifyControl`) is the one worth writing: it is the
  regression guard for the S1-3/4/5 family, and the `*Sync` methods are still `public`.
- **Rank 10** (`aWedgedTeardownDoesNotDisableTheTapForever`) is now satisfiable in spirit but
  still has no seam — `tearingDown`/`teardownStartedAt` are tap-queue-private and the sleep
  observers are installed from `init`. Factoring the `didWake` body into a method the test can
  call is the smallest change that would pin the watchdog.

---

## 2. Findings the audit missed

| # | Finding | Class | What I did |
|---|---|---|---|
| **N1** | **A tap built with no `deviceUID` is the worst possible failure: it comes up healthy.** The audit's F3 said the *diagnosis* was wrong (buffers blamed instead of the missing device). The consequence is worse than that. `AudioDeviceStart` succeeds, the aggregate delivers buffers, so `isCapturing` is true, so the engine trusts the tap — and every sample is zero, so the tap wins every vote and reports the room permanently quiet. Auto-Pause silently never pauses anything, with no error, no log line, and a green "Tap capturing (RMS 0.000)" in the pane. | **BLOCKER** | `TapDetector.swift:890-892`: refuse to build without a default output (`TapError.noOutputDevice`, `:796/:815`) and report a reason the user can act on. Recovery is automatic: the device-change listener now also sees a changed `outputDeviceUID` (F4), so plugging an output in rebuilds. |
| **N2** | **Quitting Sonar while ducked left the music paused forever.** `AppDelegate.applicationWillTerminate` only removed the event monitor; nothing called `controller.stop()` and nothing restored. The one case where the user definitely meant "stop touching Spotify" was the case where Sonar left it paused. | **BLOCKER** (a graceful quit; a force quit is unfixable — see §3) | `AutoPauseController.swift:151-167` observes `NSApplication.willTerminateNotification`; `SpotifyFadeAdapter.swift:188-224` `restoreAtShutdown()` hands the music back in at most three AppleEvents inside a 1.25 s budget, so a quit can never hang. |
| **N3** | **`PollDetector.start()` ran a Core Audio process scan synchronously on the main thread at launch** — the same function `PollDetector`'s own comment says can take *seconds* with a browser's helpers. The seed existed so the first tick would not read a false "all quiet". | **SHOULD FIX NOW** | `PollDetector.swift:114-129`: seed through `refresh()` so it lands on the scan queue. Costs at most one tick of "quiet" at startup, which resolves to a `restore()` the adapter ignores (nothing was ducked yet). |
| **N4** | A dead duplicate `case .muteOnly` in `restoreImpl` — the only pre-existing warning I removed. It sat after an earlier `.muteOnly` that always returns, so the `setVolumeSync` below it could never run. | **LATER** (removed anyway) | Deleted with the switch; behaviour is identical because the branch was unreachable. |
| **N5** | `AudioActivityTracker` registers a Core Audio property-listener block per process object and never removes one; `syncProcessList` also reads `watched` with no lock (it is queue-confined, so this is fine, but the shape invites the bug). | **LATER** | Unchanged. Moot if 6.2 is ever done. |

---

## 3. The owner's four questions

### Q1. Can the engine leave Spotify **paused when it should be playing**, with nothing scheduled to fix it?

**Yes — and this is the single most important thing in this report. No code change can fix it.**

The exact sequence, and it is the ordinary poll-only case, not a corner:

1. Screen & System Audio Recording is not granted, or the tap fails to build, or the tap dies.
   `tapIsUsable = false`, `drivingDetector == .poll` (`AutoPauseController.swift:229`).
2. Any process that is not Spotify/Sonar/a system-sound daemon holds the output. A browser tab
   with a media element, a meeting app window, a game. `AudioDetector.runningOutputProcesses`
   returns it, so poll says **loud** — and poll is answering "is something holding the device",
   not "is something making sound".
3. After `activeDuration` (0.1 s Instant / 1.0 s Fade) fusion says `.candidate` and
   `duck()` pauses Spotify.
4. The other app goes quiet but **keeps holding the output** — measured on this machine, commit
   `5d7e621`: 45 s of digital silence still read as loud.
5. `quietDuration` never elapses, so `restore()` is never called. Nothing else in the engine
   touches playback, so Spotify stays paused indefinitely, and the only explanation anywhere is
   the pane's "poll-only" label.

I looked hard for a bounded fix and rejected it. A "stuck duck" timeout is **not** a fix: the
legitimate case is a two-hour film, which poll reports as loud for two hours, and any timeout
short enough to rescue the user would bring the music back over the video. The only real repairs
are (a) get the tap working, and (b) make the user able to undo it without knowing why. (b) is
already true — pressing play relinquishes cleanly through `reconcileImpl`, and turning Auto-Pause
off calls `restore()` from `SonarEngineHost.apply:119` — but it is not discoverable.

What I *did* do is shrink the ways the app gets into this state, because each one is a silent
transition from a working tap into this failure:

- **Sleep/wake with a wedged teardown** (S1-7) put the app here for the rest of the session,
  with no log line. Now impossible: the teardown watchdog rebuilds.
- **AirPods connect/disconnect, dock, monitor** (F4) did *not* rebuild the tap at all, so after
  plugging in AirPods the app sat there believing it had loudness detection while measuring an
  output that no longer existed. Now it rebuilds.
- **A tap built with no output device** (N1) produced a green "capturing" tap that could never
  hear anything. Now a build failure with a reason.
- **A tap rebuild mid-episode** (S1-6) could itself *cause* a spurious pause. Now it holds.

Three sub-cases you asked about specifically:

- **Permission revoked mid-duck.** The tap's `isCapturing` decays within 1 s of the last buffer
  (`TapDetector.swift:489`), so the engine falls back to poll and the outcome is exactly the
  sequence above. Nothing in the engine can do better: poll's answer is all it has. What it does
  *not* do is act on a stale tap signal or double-report; trust is revoked cleanly.
- **Output device disappearing while ducked.** Before my change: no rebuild, so the app sat in
  the state above until something else changed. After: the device notification rebuilds (~1-2 s
  including the debounce) and, because I also changed what a rebuild does to a decision, the duck
  is *held* rather than dropped and re-decided — so the resume fires as soon as the tap is back
  and the quiet streak is satisfied.
- **Force quit while ducked.** **No, this cannot be fixed — no code runs on SIGKILL.** This is
  the one wrong-music-state outcome in the feature that is unavoidable, and I would rather say
  that plainly than imply otherwise. What is now covered is every exit where code *does* run:
  Cmd-Q, logout, and `NSApp.terminate` all hand the music back (N2). A force quit mid-fade can
  also leave the volume part-way down, and the same is true of it.

### Q2. Can a user be left with Spotify **playing** when they expected silence?

Mostly no, with one honest exception and one inherent one.

- The resume needs a full `quietDuration` streak, so the engine cannot resume mid-sound on the tap
  path. I checked the rebuild-hold change for this: holding during a rebuild *extends* an existing
  duck by 1-2 s but can never create a resume, so the error is in the safe direction.
- **Inherent (unchanged):** in poll-only mode the resume is *late* — music keeps playing after the
  room went quiet, for as long as some app holds the output. That is F1's mirror image and is the
  same limitation, not a separate bug.
- **The real one, unchanged: F7.** If the user pauses Spotify by hand while another app is loud,
  the engine resumes it. `player state` reads `paused` whether we paused it or they did, and
  `restoreImpl` treats `.paused` as "ours to resume". This contradicts the module's own contract
  at `SpotifyFadeAdapter.swift:30-32` and is a genuine ambiguity, not a coding mistake. The
  audit's suggested mitigation (compare track position at duck time) is not clean. Left as LATER;
  it is the only known way this feature starts music the user did not ask for.
- **Now fixed:** a graceful quit used to leave music paused (N2), and a force quit can leave the
  volume part-way down a fade.

### Q3. Does anything block the main thread or a UI path long enough to be noticed?

The audit's claim was correct about the fade and it is now false. `adapterDispatch` defaults to
`.onEngineQueue` but `SonarEngineHost.start()` sets `.onAdapterQueue` before `controller.start()`
(`SonarEngineHost.swift:69`), so in the app every `duck`/`restore`/`reconcile` hops to
`sonar.spotify-fade`. A 2 s fade is 20-50 AppleScript writes and sleeps, and the engine's 10 Hz
loop keeps evaluating streaks throughout it. Nothing on the app's side of the fence is longer than
one `queue.async`.

What I found instead, and fixed: **`PollDetector.start()` ran its process scan synchronously on the
main thread** (N3) — the one call the engine's own comments say can take seconds with a browser's
helpers, reached from `applicationDidFinishLaunching` via `controller.start()`. That was a
multi-second frozen menu bar on the first launch after login, and it was more likely to be noticed
than anything in the fade path.

Two things I did **not** fix, and you should route them:

- `Sonar/Engine/RecentSourcesModel.swift:85-87` runs a 5 s **main-thread** `Timer` that calls
  the same `AudioDetector.runningOutputProcesses()`. This is a more frequent freeze risk than
  anything in the engine, and it is in agent-ui's file.
- The IOProc takes two locks per audio block (`TapDetector.swift:1173`). Not the main thread, but
  an IOProc that blocks can glitch the output it is clocking. The real fix is a lock-free atomic
  counter plus a format snapshot taken at build time; that is not a release-sized change.

### Q4. Crash risks on the tap/teardown path, which now runs on several queues?

I found none, and I looked for the specific things you named:

- **Force unwraps.** Two exist in the package, both in `FusionState.evaluate:46` and `:56`, and
  both are `loudSince!`/`quietSince!` assigned on the immediately preceding line in the same
  branch. No `try!`, no `as!`, no `unowned`.
- **Array indexing.** `TapMeter.rms` derives its element count from the buffer's own
  `mDataByteSize`, so a wrong `isFloat` misreads the samples but can never read past the end.
  `fade(to:over:generation:)` guards `steps >= 1` before the `1...steps` loop.
- **Lock ordering.** `lock` and `callbackLock` are never held together anywhere in the class, so
  there is no inversion and no nesting deadlock. I re-checked the new code against that: the
  teardown watchdog only touches tap-queue-confined fields, and `rebuildIfNeeded` is reached only
  from `queue.async` (start/stop/`didSet`/HAL listeners/sleep observers/retry/teardown
  completion), so `_isRebuilding` is never touched off the tap queue.
- **The new shutdown path** blocks the main thread on a semaphore for up to 1.25 s, but it takes
  no lock while waiting, its work runs on the adapter queue, and its only outbound callback hops
  to main with `async`. No cycle.
- **`deinit`** reads `ioProc`/`aggregateID`/`tapID` without the lock. Word-sized object IDs, no
  torn value, and `deinit` cannot run while a tap-queue block holds a strong `self`.

One residual, pre-existing: the two HAL property-listener blocks registered in
`installSystemListeners()` are never removed, so after a `TapDetector` is deallocated coreaudiod
keeps firing blocks that hop onto a dead queue. They capture `self` weakly, so it is a small leak,
not a crash. The app creates one detector for the process lifetime.

---

## 4. Changes made

All in `Packages/AutoPauseEngine/Sources/AutoPauseEngine/`. `git diff --stat`: 7 files,
+304/-23 — most of the additions are the comments explaining *why*, no renames, no
reorganisations, no restyling.

| File | Change | Why it is safe this close to a release |
|---|---|---|
| `TapDetector.swift` | Teardown watchdog (`teardownStartedAt`, `teardownWatchdog = 5 s`, the `if` in `rebuildIfNeeded`). | Pure addition to a guard that previously deferred *forever*. The new branch only runs when a teardown has already been in flight for 5 s, which today means the tap is dead anyway. The only new state is a timestamp, cleared on the same path that clears `tearingDown`. |
| `TapDetector.swift` | `outputDeviceUID` added to `TapTargets` and filled from the existing `defaultOutputDeviceUID()`. | `TapTargets` is `private` and `Equatable`; adding a field turns a previously silent no-op (a device change hitting the "targets unchanged" early return) into a rebuild. The debounce is unchanged, so a Bluetooth device merely being *discovered* (default unchanged) still does not rebuild. |
| `TapDetector.swift` | `buildTap` now throws `TapError.noOutputDevice` when there is no default output. | Changes a silent, unrecoverable, zero-volume-detected failure into a reported one with the retry that already existed. On a machine that *does* have a default output — every machine the feature works on today — the code path is byte-identical. |
| `TapDetector.swift` | `isRebuilding` (new public read-only property, lock-protected). | Additive to the public API. Only a new build can set it. |
| `TapDetector.swift` | `retryAttempts` capped at 120 with a log line. | Sized so the cap cannot be reached by a real user (delay saturates at 30 s → ~1 h) and so the live-grant path is untouched in every realistic session. Reset by a successful build, and wake/rules-change rebuilds bypass it entirely. |
| `TapDetector.swift` | The `.starved` error now carries the real format. | Captures a value one line earlier. No control flow change. |
| `TapDetector.swift` | `handleAudioBlock` doc comment rewritten. | Comment only. |
| `AutoPauseController.swift` | A rebuild holds the decision instead of handing the vote to poll; `.tapVerified` no longer re-announces per rebuild. | The new branch can only *withhold* a decision — it can never invent one and never starts or ends an episode, so it cannot cause a duck that did not happen or miss a resume that was earned. `.hold` is a decision the switch already handled (`break`). |
| `AutoPauseController.swift` | `NSApplication.willTerminateNotification` observer + removal in `stop()`; `import AppKit` (already a package dependency). | Additive; guarded so repeated `start()` cannot stack observers; removed on `stop()`. No test calls `start()`, so the suite is unaffected. |
| `SpotifyFadeAdapter.swift` | `restoreAtShutdown()` + `releaseOwnership()`; removed the unreachable duplicate `case .muteOnly`. | Deliberately **not** a parameter on `restoreImpl`: a separate 30-line decision keeps the 40-odd heavily-tested ownership assertions untouched. It reuses the tested rules (same pid, never play a stopped player, preserve a user volume change) with the volume read folded into the one `stateAndVolume` round trip, which is what keeps it inside 1.25 s. Guarded by `isOwned`, so a normal quit costs nothing. |
| `SpotifyControl.swift` | `run(_:)` returns nil on an AppleEvent error. | One added `guard`. It only changes the failure path: a reply that was previously an error *message* is now nil, which every caller already handles as "unreadable". |
| `PollDetector.swift` | `start()` seeds via `refresh()` instead of a synchronous scan. | Removes a main-thread block. Costs at most one tick of startup "quiet", which cannot resume anything because nothing is owned yet. No test calls `poll.start()`. |
| `AudioActivityTracker.swift` | `Array(startedAt.keys)` in `observe`. | Semantically identical, one line, removes a per-scan dictionary copy. |
| `AudioDetector.swift` | Scan-cost comment corrected. | Comment only. |

Public API added: `TapDetector.isRebuilding`, `SpotifyFadeAdapter.restoreAtShutdown()`.
Nothing removed or changed in signature, so nothing in `Sonar/` can break.

---

## 5. Required patches in files I do not own

Not applied. Each is small and specific.

1. **`Sonar/Engine/RecentSourcesModel.swift:111`** — the same mutate-during-iterate line as S1-8
   (`for id in seen.keys where … { seen[id] = nil }`), reachable from a 5 s **main-thread** `Timer`,
   so unlike the engine copy it is not academic. Also note the force unwrap in the same line
   (`seen[id]!`), which is safe only because `id` came from `seen.keys`:
   ```swift
   for id in Array(seen.keys) where now.timeIntervalSince(seen[id]!.at) > window {
       seen[id] = nil
   }
   ```
2. **`Sonar/Engine/RecentSourcesModel.swift:85-87`** — the 5 s main-thread `Timer` calls
   `refresh()`, which calls the same profiled-slow `AudioDetector.runningOutputProcesses()`.
   Move it off main, or share one scan with `PollDetector` (audit §6.7). This is the most likely
   main-thread freeze in the app.
3. **`Sonar/Engine/SonarEngineHost.swift:166-167`** — `.skippedNotPlaying` sets a label but writes
   no log line, so a revoked Automation grant (F2) leaves no evidence at all. One `SonarLog.write`.
4. **`AutoPausePreferencesView.swift:994-1000` (`drivingDetectorText`)** —
   still uses `host.tapIsOperational` although the host now publishes the authoritative
   `drivingDetector` (audit §6.10). One line, and it removes the last place the two can disagree.
5. **`Sonar/App/AppDelegate.swift:97-101`** — `applicationWillTerminate` should call
   `engineHost.controller.stop()` (F9). Note this is now *nice to have* rather than music-affecting:
   the new `willTerminate` observer already hands the music back before the process goes. It is
   still the right thing to do on the way out — it cancels the tick timer and tears the tap down
   deterministically, which the observer does not do.
6. **`Sonar/Preferences/AutoPausePreferencesModel.swift:155,165`** — the stale single
   `presetThreshold = 0.02` for both presets (audit §6.11). Per the contract this is already
   coordinated and unblocked on the engine side: `AutoPausePreset.threshold` exists
   (`AutoPausePreset.swift:78-83`) and `matches(…threshold:)` has no default
   (`AutoPausePreset.swift:97-111`), so the fix is to pass `Double(preset.threshold)` in both
   places.
7. **`Sonar/Engine/SonarEngineHost.swift:99`** — `gapConfig.gapTolerance = 0.15` is a hard-coded
   constant that does not follow `prefs.quietDuration` (audit §2d #6). Deleting it would make
   Instant's 0.3 s mean 0.3 s, but it changes the *feel* of the product, so it is a decision, not
   a patch.

---

## 6. What I did not run

Only `swift build` and `swift test` on `Packages/AutoPauseEngine`, five times, as instructed.
No audio was played, no AppleEvent was sent to Spotify (every adapter test constructs
`FakeSpotifyControl`; the one test that builds a real `SpotifyFadeAdapter()`,
`AutoPauseEngineTests.swift:18`, only reads `mode` and the bundle ID), nothing was installed, no
TCC permission was read for a request, none was reset, and no script was run.

One disclosure: `TapDetectorTests.swift:135-145` (`aDetectorStartsIdleAndStopsIdleSoTheEngineCanPollIt`)
calls `TapDetector().start()` **unconditionally**, so every `swift test` run attempts a real tap
build — which may create and destroy a private aggregate device and may put the system
screen-recording prompt on screen if the grant is absent. That is pre-existing (it happened in the
baseline run before I changed anything) and it is the reason the suite is not as
hardware-free as its own comments claim. It is the tests agent's file, so I did not change it; it
ought to be env-gated like its two neighbours.
