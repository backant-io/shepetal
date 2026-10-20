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
    // the next tap ends it and transcribes.
    func testDoubleTapLocksHandsFreeAndTapEndsIt() {
        var g = FnGesture()
        _ = g.fnDown(at: 0)
        _ = g.fnUp(at: 0.1)
        XCTAssertEqual(g.fnDown(at: 0.5), [.lockHandsFree])
        XCTAssertEqual(g.fnUp(at: 0.55), [], "release while locked keeps recording")
        XCTAssertEqual(g.tick(at: 10), [], "no short-press timer while locked")
        XCTAssertEqual(g.fnDown(at: 30), [.stop])
        XCTAssertEqual(g.fnUp(at: 30.1), [])
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
        XCTAssertEqual(h.state, .handsFree)
        XCTAssertEqual(h.otherKeyDown(at: 9), [])
    }

    func testFnKeyClassification() {
        XCTAssertEqual(FnKey.transition(keycode: 63, secondaryFn: true, isKeyDown: nil), true)
        XCTAssertEqual(FnKey.transition(keycode: 63, secondaryFn: false, isKeyDown: nil), false)
        XCTAssertEqual(FnKey.transition(keycode: 179, secondaryFn: false, isKeyDown: true), true)
        XCTAssertEqual(FnKey.transition(keycode: 179, secondaryFn: true, isKeyDown: false), false)
        // Arrow keys carry the secondary-fn flag too; they are not fn.
        XCTAssertNil(FnKey.transition(keycode: 123, secondaryFn: true, isKeyDown: true))
        XCTAssertNil(FnKey.transition(keycode: 56, secondaryFn: false, isKeyDown: nil))
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
