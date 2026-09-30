import Foundation
import Testing
@testable import AutoPauseEngine

/// The permission rows in Preferences show "waiting" for as long as a request is
/// outstanding, and the request only used to end when the OS answered it.
///
/// `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true)` blocks on a
/// system dialog. Dismiss that dialog without answering, or quit the app while
/// it is up, and the call never returns — so the flag recording "a request is
/// in flight" outlived the thing it described. The Automation row then read
/// "Checking…" for the rest of the session, `.unknown` was what the UI showed
/// for a request as well as for a state nobody had read yet, no "Grant…" button
/// was ever built, and Auto-Pause could not be switched on. There was no state
/// to reach and nothing to press.
///
/// The fix is not "clear the flag in more places". It is that an entry can only
/// be left by an answer or by a deadline, and `expire(at:)` is a pure function
/// of the clock, so the caller cannot forget to call it. These tests drive that
/// contract: the interesting case is the request that never answers at all.

private let start = Date(timeIntervalSince1970: 1_700_000_000)

@Test func aRequestThatNeverReturnsStopsCountingAsInFlightAtItsDeadline() {
    var ledger = InFlightLedger<String>()
    ledger.begin("automation", at: start, timeout: InFlightTimeout.grantRequest)
    #expect(ledger.contains("automation"))
    #expect(ledger.keys == ["automation"])

    // The dialog is up and nobody ever answers it, so nothing calls `finish` —
    // not a timeout, not a dismissal, not an app activation. Nothing but the
    // clock can end this.
    let justBefore = start.addingTimeInterval(InFlightTimeout.grantRequest - 0.5)
    #expect(ledger.expire(at: justBefore).isEmpty, "gave up before the request could be answered")
    #expect(ledger.contains("automation"), "an unexpired request is still in flight")

    let deadline = start.addingTimeInterval(InFlightTimeout.grantRequest)
    #expect(ledger.expire(at: deadline) == ["automation"])
    // This is the whole defect: while this is true, the row says "Checking…",
    // offers no action, and can never resolve.
    #expect(!ledger.contains("automation"), "the row would sit on Checking… forever")
    #expect(ledger.keys.isEmpty)
    #expect(ledger.isEmpty)
}

@Test func aLateAnswerToAnExpiredRequestCannotResurrectIt() {
    // The OS call is blocked in C, not cancelled. When it finally does return —
    // minutes later, maybe after the app was relaunched — the answer describes
    // the world at some unknown time in the past, and `finish` is a no-op
    // because there is nothing left to finish. Pushing the stale answer back
    // into the row would be a state nothing has verified.
    var ledger = InFlightLedger<String>()
    ledger.begin("automation", at: start, timeout: InFlightTimeout.grantRequest)
    ledger.expire(at: start.addingTimeInterval(InFlightTimeout.grantRequest))
    let finishedNothing = ledger.finish("automation")
    #expect(finishedNothing == false)
    #expect(ledger.isEmpty)
}

@Test func aReadThatNeverAnswersStopsBlockingLaterReads() {
    // Same shape, different victim. The reads share a queue and a `guard
    // !isBusy`, so one read that never returned left `isBusy` set for good and
    // nothing could be re-read — the switch had no off position, and both rows
    // were frozen at "Checking…" with no way forward.
    var ledger = InFlightLedger<String>()
    ledger.begin("read", at: start, timeout: InFlightTimeout.probe)
    #expect(ledger.contains("read"))

    // Well past a probe timeout (these answer in microseconds), but before
    // anybody has swept: still blocking, and the sweep is what releases it.
    let stuck = start.addingTimeInterval(InFlightTimeout.probe * 10)
    #expect(ledger.contains("read"), "expired does not mean released on its own")
    #expect(ledger.isExpired("read", at: stuck))

    #expect(ledger.expire(at: stuck) == ["read"])
    #expect(ledger.isEmpty)
    // And the next read is allowed to start, which is the recovery.
    ledger.begin("read", at: stuck, timeout: InFlightTimeout.probe)
    #expect(ledger.contains("read"))
}

@Test func aProbeTimeoutIsShorterThanAGrantDialogWait() {
    // The two are not the same operation and must not share a number. A read
    // answers in microseconds, so three seconds means "wedged" and the recovery
    // is to start another one. A grant request is waiting on a person, so its
    // deadline has to be long enough for a person — and long enough that the
    // row is not lying about what it is doing while they answer the dialog.
    #expect(InFlightTimeout.probe < InFlightTimeout.grantRequest)
    #expect(InFlightTimeout.probe >= 1, "too tight to survive a loaded machine")
    #expect(InFlightTimeout.grantRequest >= 30, "not long enough to read a system dialog")
}

@Test func aReadThatNeverAnswersIsNotRetriedUntilSomethingCouldHaveChangedIt() {
    // The bug this pins was found by measurement, not by reasoning: the poll
    // fired every second, each tick started a fresh read because the previous
    // one was past its deadline, and the reads shared a serial queue — so
    // nothing ever ran. 14 calls started, 0 finished, in 14 seconds, each one
    // holding a thread. A deadline has to *stop* the retrying, not merely let
    // the next one start.
    var ledger = InFlightLedger<String>()
    ledger.begin("automation", at: start, timeout: InFlightTimeout.probe)

    let timedOut = start.addingTimeInterval(InFlightTimeout.probe)
    #expect(ledger.expire(at: timedOut) == ["automation"])
    #expect(!ledger.contains("automation"), "nothing is outstanding, so nothing is queued behind it")

    // What the app does with that: a cooldown, cleared by coming back to the
    // app (a trip to System Settings is the usual reason to be there) rather
    // than by a second having passed.
    let cooldownUntil = timedOut.addingTimeInterval(InFlightTimeout.wedgedReadRetry)
    #expect(cooldownUntil > timedOut)
    #expect(cooldownUntil <= timedOut.addingTimeInterval(InFlightTimeout.wedgedReadRetry))
    // Before it expires, no new read is started.
    #expect(cooldownUntil > timedOut.addingTimeInterval(1))
}

@Test func aWedgedReadRetryFloorIsLongEnoughToMatter() {
    // A floor of a second or two would be the same unbounded pile-up wearing a
    // different hat. It only has to be short enough that a user who fixes
    // something and comes back is not left waiting, and that path is the
    // activation event, not this number.
    #expect(InFlightTimeout.wedgedReadRetry >= 30)
    #expect(InFlightTimeout.wedgedReadRetry > InFlightTimeout.probe)
}

@Test func oneWedgedReadDoesNotHoldUpTheOther() {
    // The two permission checks are nothing alike, and reading them as one
    // serial job meant the reliable one was never published. This is the log
    // from the shipped build on the affected machine, hours into a session whose
    // audio tap was working perfectly the whole time:
    //
    //     permissions: loudness measurement working (preflight says unknown)
    //
    // `unknown` for the screen-recording row, forever, because it was read in
    // the same batch as the Automation call that never returns. So the two are
    // tracked separately here, and the fast one is free to complete on its own.
    var reads = InFlightLedger<String>()
    let now = start

    reads.begin("screenRecording", at: now, timeout: InFlightTimeout.probe)
    reads.begin("automation", at: now, timeout: InFlightTimeout.probe)

    // The reliable one answers straight away.
    let answered = reads.finish("screenRecording")
    #expect(answered)
    #expect(!reads.contains("screenRecording"))
    #expect(reads.contains("automation"), "the wedged one is still outstanding")

    // ...and the wedged one is given up on without disturbing the answer.
    let later = now.addingTimeInterval(InFlightTimeout.probe)
    #expect(reads.expire(at: later) == ["automation"])
    #expect(reads.isEmpty)
    // Whatever the fast one published is untouched by the slow one going away.
    #expect(reads.expire(at: later.addingTimeInterval(3600)).isEmpty)
}

@Test func aRequestThatIsAnsweredInTimeIsNotGivenUp() {
    // The deadline is a floor on how long the UI keeps waiting, not a timer
    // that fires regardless: an answer always wins the race.
    var ledger = InFlightLedger<String>()
    ledger.begin("automation", at: start, timeout: InFlightTimeout.grantRequest)
    let answered = start.addingTimeInterval(InFlightTimeout.grantRequest / 2)
    let hadSomethingToFinish = ledger.finish("automation")
    #expect(hadSomethingToFinish)
    #expect(!ledger.contains("automation"))
    let expiredAfter = ledger.expire(at: answered.addingTimeInterval(600))
    #expect(expiredAfter.isEmpty, "it answered already")
}

@Test func oneExpiredRequestDoesNotDisturbAnotherThatIsStillInFlight() {
    // Automation and Screen Recording are independent rows with independent
    // dialogs, and one of them hanging must not unblock the other's row.
    var ledger = InFlightLedger<String>()
    ledger.begin("automation", at: start, timeout: InFlightTimeout.grantRequest)
    ledger.begin("screenRecording", at: start, timeout: InFlightTimeout.grantRequest)
    let later = start.addingTimeInterval(InFlightTimeout.grantRequest)
    // Automation is first in the dictionary, but the sweep cannot depend on
    // that: it hands back only what actually expired.
    ledger.begin("screenRecording", at: start, timeout: InFlightTimeout.grantRequest * 2)
    #expect(ledger.expire(at: later) == ["automation"])
    #expect(ledger.contains("screenRecording"))
    #expect(ledger.keys == ["screenRecording"])
}

@Test func comingBackToTheAppGivesUpOnEveryWaitAtOnce() {
    // The dialog belonged to the OS and is not up any more by the time the app
    // is active again, so no request is still waiting — whatever the deadline
    // says. One call clears them all, which is what makes the Automation row
    // recover instantly after Settings -> back to the window.
    var ledger = InFlightLedger<String>()
    ledger.begin("automation", at: start, timeout: InFlightTimeout.grantRequest)
    ledger.begin("screenRecording", at: start, timeout: InFlightTimeout.grantRequest)
    let gaveUp = ledger.expire("automation")
    let alsoGaveUp = ledger.expire("screenRecording")
    #expect(gaveUp)
    #expect(alsoGaveUp)
    #expect(ledger.isEmpty)
}

@Test func beginningARequestTwiceRestartsItsClockInsteadOfQueuingASecondDeadline() {
    // Two deadlines for one dialog: the shorter one expires, the row says it
    // has given up, and the request is still genuinely running underneath.
    var ledger = InFlightLedger<String>()
    ledger.begin("automation", at: start, timeout: InFlightTimeout.grantRequest)
    let again = start.addingTimeInterval(30)
    ledger.begin("automation", at: again, timeout: InFlightTimeout.grantRequest)
    #expect(ledger.count == 1)
    #expect(ledger.startedAt("automation") == again)
    #expect(ledger.isExpired("automation", at: again.addingTimeInterval(InFlightTimeout.grantRequest)))
    #expect(!ledger.isExpired("automation", at: again.addingTimeInterval(InFlightTimeout.grantRequest - 1)))
    #expect(ledger.deadline(for: "automation") == again.addingTimeInterval(InFlightTimeout.grantRequest))
}
