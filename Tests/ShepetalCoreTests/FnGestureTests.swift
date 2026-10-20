import XCTest
@testable import ShepetalCore

final class FnGestureTests: XCTestCase {
    // Hold to talk: a press longer than the hold threshold records and transcribes on release.
    func testHoldTalksAndReleaseTranscribes() {
        var g = FnGesture()
        XCTAssertEqual(g.fnDown(at: 10), [.start])
        XCTAssertEqual(g.fnUp(at: 10.6), [.stop])
        XCTAssertEqual(g.state, .idle)
    }

    // The 500 ms threshold is a product decision: 0.49 s is a tap, 0.5 s is a hold.
    func testHoldThresholdBoundary() {
        var g = FnGesture()
        _ = g.fnDown(at: 0)
        XCTAssertEqual(g.fnUp(at: 0.49), [], "a 0.49 s press must not transcribe yet")
        XCTAssertEqual(g.deadline!, 0.99, accuracy: 1e-9)

        var h = FnGesture()
        _ = h.fnDown(at: 0)
        XCTAssertEqual(h.fnUp(at: 0.5), [.stop], "a 0.5 s press is a hold")
    }

    // Too-short press: nothing is transcribed or inserted, the shell shows the hint and keeps the audio.
    func testShortPressIsDroppedWithHint() {
        var g = FnGesture()
        _ = g.fnDown(at: 0)
        _ = g.fnUp(at: 0.2)
        XCTAssertEqual(g.tick(at: 0.69), [], "still inside the double-tap window")
        XCTAssertEqual(g.tick(at: 0.7), [.tooShort])
        XCTAssertEqual(g.state, .idle)
        XCTAssertEqual(g.tick(at: 5), [], "settled once")
    }

    func testHintWordingAndDuration() {
        XCTAssertTrue(Hint.shortPress.contains("Hold fn"), Hint.shortPress)
        XCTAssertTrue(Hint.shortPress.contains("double-tap"), Hint.shortPress)
        XCTAssertEqual(Hint.seconds, 2, accuracy: 0.5)
    }

    // Double-tap: the second press inside the window locks hands-free; release does not stop it;
    // the next tap ends it and transcribes. The tap ends it on release, so that fn+Space (the toggle)
    // stops hands-free instead of fn stopping it and Space starting a new one.
    func testDoubleTapLocksHandsFreeAndTapEndsIt() {
        var g = FnGesture()
        _ = g.fnDown(at: 0)
        _ = g.fnUp(at: 0.1)
        XCTAssertEqual(g.fnDown(at: 0.5), [.lockHandsFree])
        XCTAssertEqual(g.state, .handsFree(since: 0), "the session started at the first press")
        XCTAssertEqual(g.fnUp(at: 0.55), [], "release while locked keeps recording")
        XCTAssertEqual(g.tick(at: 10), [], "no short-press timer while locked")
        XCTAssertEqual(g.fnDown(at: 30), [])
        XCTAssertEqual(g.fnUp(at: 30.1), [.stop])
        XCTAssertEqual(g.state, .idle)
    }

    // A second press just after the window is not a double-tap: the first press is too short
    // and the new press starts a fresh hold.
    func testSecondPressAfterWindowIsNewHold() {
        var g = FnGesture()
        _ = g.fnDown(at: 0)
        _ = g.fnUp(at: 0.1)
        XCTAssertEqual(g.fnDown(at: 0.61), [.tooShort, .start])
        XCTAssertEqual(g.fnUp(at: 2), [.stop])
    }

    func testRepeatedDownWhileHoldingIsIgnored() {
        var g = FnGesture()
        _ = g.fnDown(at: 0)
        XCTAssertEqual(g.fnDown(at: 0.1), [])
        XCTAssertEqual(g.fnUp(at: 1), [.stop])
    }

    // fn is also a modifier: fn+Delete, fn+arrows (Page Up/Down, Home, End), fn+F-keys. Another key
    // pressed in the first second of a hold means a shortcut, so nothing is transcribed or pasted
    // (docs/re/dictation-input.md 1, "Chord collision cancels").
    func testShortcutWithFnCancels() {
        var g = FnGesture()
        _ = g.fnDown(at: 0)
        XCTAssertEqual(g.otherKeyDown(at: 0.2), [.cancel])
        XCTAssertEqual(g.otherKeyDown(at: 0.3), [], "key repeat after the cancel")
        XCTAssertEqual(g.fnUp(at: 0.8), [], "a long fn+Down must not transcribe")
        XCTAssertNil(g.deadline, "no short-press hint either")
        XCTAssertEqual(g.state, .idle)

        var quick = FnGesture()
        _ = quick.fnDown(at: 0)
        XCTAssertEqual(quick.otherKeyDown(at: 0.05), [.cancel], "quick fn+Delete")
        XCTAssertEqual(quick.fnUp(at: 0.1), [])
        XCTAssertEqual(quick.tick(at: 5), [])
    }

    // After the first second the user is talking; a key pressed then does not throw the dictation away.
    // Hands-free is not a held chord at all.
    func testKeysAfterTheChordWindowOrInHandsFreeKeepRecording() {
        var g = FnGesture()
        _ = g.fnDown(at: 0)
        XCTAssertEqual(g.otherKeyDown(at: 1.0), [])
        XCTAssertEqual(g.fnUp(at: 3), [.stop])

        var h = FnGesture()
        _ = h.fnDown(at: 0)
        _ = h.fnUp(at: 0.1)
        _ = h.fnDown(at: 0.3)
        XCTAssertEqual(h.otherKeyDown(at: 0.4), [])
        XCTAssertEqual(h.state, .handsFree(since: 0))
        XCTAssertEqual(h.otherKeyDown(at: 9), [])
        // fn+Delete while hands-free is a shortcut, so its fn release is not the stop tap.
        XCTAssertEqual(h.fnDown(at: 12), [])
        XCTAssertEqual(h.otherKeyDown(at: 12.1), [])
        XCTAssertEqual(h.fnUp(at: 12.3), [])
        XCTAssertEqual(h.state, .handsFree(since: 0))
    }

    // MARK: Esc (F03)

    func testEscCancelsHoldHandsFreeAndPendingTap() {
        var hold = FnGesture()
        _ = hold.fnDown(at: 0)
        XCTAssertEqual(hold.dismiss(), [.cancel])
        XCTAssertEqual(hold.fnUp(at: 3), [], "the release after Esc must not transcribe")
        XCTAssertEqual(hold.state, .idle)

        var locked = FnGesture()
        _ = locked.toggle(at: 0)
        XCTAssertEqual(locked.dismiss(), [.cancel])
        XCTAssertEqual(locked.state, .idle)

        var pending = FnGesture()
        _ = pending.fnDown(at: 0)
        _ = pending.fnUp(at: 0.1)
        XCTAssertEqual(pending.dismiss(), [.cancel])
        XCTAssertEqual(pending.tick(at: 1), [], "cancelled, so no too-short hint afterwards")
    }

    func testEscWhenIdleDoesNothing() {
        var g = FnGesture()
        XCTAssertEqual(g.dismiss(), [])
        var k = Keys()
        XCTAssertEqual(k.press(Key.esc, at: 0), [])
        XCTAssertFalse(k.lastSwallowed, "the app gets its Esc")
    }

    // MARK: chord promotion and the hands-free toggle (F02, F04)

    func testFnSpacePromotesHoldToHandsFree() {
        var k = Keys()
        XCTAssertEqual(k.press(Key.fn, at: 0), [.start])
        let space = k.press(Key.space, at: 0.3)
        XCTAssertFalse(space.contains(.cancel), "Space inside the first second completes fn+Space, it is no chord collision")
        XCTAssertEqual(space, [.lockHandsFree])
        XCTAssertTrue(k.lastSwallowed, "the front app never gets that Space")
        XCTAssertEqual(k.release(Key.space, at: 0.4), [])
        XCTAssertEqual(k.release(Key.fn, at: 0.5), [], "releasing fn no longer ends it")
        XCTAssertEqual(k.gesture.state, .handsFree(since: 0))

        // fn+Space again stops it once: fn going down must not stop it before Space toggles a new one.
        XCTAssertEqual(k.press(Key.fn, at: 20), [])
        XCTAssertEqual(k.press(Key.space, at: 20.1), [.stop])
        XCTAssertEqual(k.release(Key.space, at: 20.2), [])
        XCTAssertEqual(k.release(Key.fn, at: 20.3), [])
        XCTAssertEqual(k.gesture.state, .idle)
    }

    func testOtherChordStillCancelsInFirstSecond() {
        var k = Keys()
        _ = k.press(Key.fn, at: 0)
        XCTAssertEqual(k.press(Key.delete, at: 0.3), [.cancel], "fn+Delete is forward delete, not dictation")
        XCTAssertFalse(k.lastSwallowed, "and the app still gets it")
        XCTAssertEqual(k.release(Key.fn, at: 0.8), [])
    }

    func testToggleStartsLocked() {
        var g = FnGesture()
        XCTAssertEqual(g.toggle(at: 5), [.start, .lockHandsFree])
        XCTAssertEqual(g.state, .handsFree(since: 5))
        XCTAssertEqual(g.otherKeyDown(at: 5.2), [], "typing while locked keeps recording")
    }

    func testToggleAgainWithinHalfSecondCancels() {
        var g = FnGesture()
        _ = g.toggle(at: 0)
        XCTAssertEqual(g.toggle(at: 0.49), [.cancel])
        XCTAssertEqual(g.state, .idle)
    }

    func testToggleLaterStops() {
        var g = FnGesture()
        _ = g.toggle(at: 0)
        XCTAssertEqual(g.toggle(at: 0.5), [.stop], "0.5 s is no longer a double press")
        XCTAssertEqual(g.state, .idle)
    }

    // MARK: max length (F10)

    func testWarningOneMinuteBeforeCapThenForcedStop() {
        var hold = FnGesture()
        _ = hold.fnDown(at: 0)
        var locked = FnGesture()
        _ = locked.fnDown(at: 0)
        _ = locked.fnUp(at: 0.1)
        _ = locked.fnDown(at: 0.3)
        for g in [hold, locked] {
            var g = g
            XCTAssertEqual(g.tick(at: 19 * 60 - 1), [])
            XCTAssertEqual(g.tick(at: 19 * 60), [.warnDuration])
            XCTAssertEqual(g.tick(at: 19 * 60 + 30), [], "the warning shows once")
            XCTAssertEqual(g.tick(at: 20 * 60), [.stop], "forced stop: transcribed and inserted like a release")
            XCTAssertEqual(g.state, .idle)
            XCTAssertEqual(g.fnUp(at: 20 * 60 + 5), [], "the late release does nothing")
            XCTAssertEqual(g.tick(at: 30 * 60), [])
        }
    }

    func testReleaseBeforeCapHasNoWarning() {
        var g = FnGesture()
        _ = g.fnDown(at: 0)
        XCTAssertEqual(g.fnUp(at: 10 * 60), [.stop])
        XCTAssertNil(g.deadline)
        XCTAssertEqual(g.tick(at: 19 * 60), [])
        XCTAssertEqual(g.tick(at: 20 * 60), [])

        // A new session after a warned one warns again.
        _ = g.fnDown(at: 100)
        XCTAssertEqual(g.tick(at: 100 + 19 * 60), [.warnDuration])
        _ = g.fnUp(at: 100 + 19 * 60 + 1)
        _ = g.toggle(at: 2000)
        XCTAssertEqual(g.tick(at: 2000 + 19 * 60), [.warnDuration])
    }

    func testCapIsConfigurable() {
        var g = FnGesture()
        g.maxDuration = 5 * 60
        _ = g.toggle(at: 0)
        XCTAssertEqual(g.tick(at: 4 * 60), [.warnDuration])
        XCTAssertEqual(g.tick(at: 5 * 60), [.stop])
    }

    func testDeadlineIsTheEarliestPendingTimer() {
        var g = FnGesture()
        XCTAssertNil(g.deadline, "idle has no timer")
        _ = g.fnDown(at: 0)
        XCTAssertEqual(g.deadline!, 19 * 60, accuracy: 1e-9, "the warning comes first")
        _ = g.fnUp(at: 0.2)
        XCTAssertEqual(g.deadline!, 0.7, accuracy: 1e-9, "a short press settles long before any cap")
        _ = g.fnDown(at: 0.4)
        XCTAssertEqual(g.deadline!, 19 * 60, accuracy: 1e-9, "locked: the warning, counted from the first press")
        _ = g.tick(at: 19 * 60)
        XCTAssertEqual(g.deadline!, 20 * 60, accuracy: 1e-9, "after the warning: the cap")
    }
}

/// The key router and the gesture together, as the app wires them.
struct Keys {
    var router = KeyRouter()
    var gesture = FnGesture()
    var lastSwallowed = false

    mutating func press(_ code: Int, at t: TimeInterval) -> [GestureAction] { event(code, true, t) }
    mutating func release(_ code: Int, at t: TimeInterval) -> [GestureAction] { event(code, false, t) }

    private mutating func event(_ code: Int, _ down: Bool, _ t: TimeInterval) -> [GestureAction] {
        let out = router.key(code, down: down, active: gesture.state != .idle, canSwallow: true)
        lastSwallowed = out.swallow
        return out.inputs.flatMap { gesture.handle($0, at: t) }
    }
}

final class ModelTierTests: XCTestCase {
    func testMacTiers() {
        XCTAssertEqual(modelTier(appleSilicon: true, ramGB: 8), ModelTier(primary: .parakeetV3, fallback: .whisperBaseEn))
        XCTAssertEqual(modelTier(appleSilicon: true, ramGB: 16), ModelTier(primary: .parakeetV3, fallback: .whisperLargeV3Turbo))
        XCTAssertEqual(modelTier(appleSilicon: true, ramGB: 24), ModelTier(primary: .parakeetV3, fallback: .whisperLargeV3Turbo))
        // Parakeet's CoreML build needs Apple Silicon.
        XCTAssertEqual(modelTier(appleSilicon: false, ramGB: 64), ModelTier(primary: .whisperBaseEn, fallback: nil))
    }
}
