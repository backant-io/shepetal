import XCTest
@testable import ShepetalCore

final class ChimeTests: XCTestCase {
    // Short so it never talks over the user, quiet so it never startles, faded so it never clicks.
    func testEachSoundIsShortQuietAndFaded() {
        for chime in Chime.allCases {
            let s = chime.samples
            XCTAssertFalse(s.isEmpty, "\(chime)")
            XCTAssertLessThanOrEqual(s.count, AudioStore.sampleRate * 150 / 1000, "\(chime) longer than 150 ms")
            XCTAssertLessThanOrEqual(s.map(abs).max()!, 0.5, "\(chime) louder than -6 dBFS")
            XCTAssertLessThan(abs(s.first!), 0.01, "\(chime) starts with a click")
            XCTAssertLessThan(abs(s.last!), 0.01, "\(chime) ends with a click")
        }
    }

    func testSoundsDiffer() {
        let all = Chime.allCases.map(\.samples)
        for i in all.indices { for j in all.indices where i < j { XCTAssertNotEqual(all[i], all[j]) } }
    }

    // Pitch shows as the zero-crossing rate: start goes up, stop comes down.
    func testStartRisesStopFalls() {
        func halves(_ s: [Float]) -> (Int, Int) {
            let mid = s.count / 2
            return (crossings(s[..<mid]), crossings(s[mid...]))
        }
        let start = halves(Chime.start.samples), stop = halves(Chime.stop.samples)
        XCTAssertLessThan(start.0, start.1)
        XCTAssertGreaterThan(stop.0, stop.1)
    }

    /// The sounds heard for a run of fn events through the real gesture machine, with the shell's
    /// hold-threshold check after each `.start`. `events` are (time, "down" / "up" for fn, "key" for
    /// another key, "tick" for the gesture timer).
    private func heard(_ events: [(TimeInterval, String)]) -> [Chime] {
        var g = FnGesture(), cue = ChimeCue(), out: [Chime] = []
        var checks: [TimeInterval] = []
        func handle(_ actions: [GestureAction], _ t: TimeInterval) {
            for a in actions {
                if a == .start { checks.append(t + g.holdThreshold) }
                if let c = cue.sound(for: a) { out.append(c) }
            }
        }
        for (t, e) in events {
            for c in checks where c <= t { if let s = cue.holdCheck(g, at: c) { out.append(s) } }
            checks.removeAll { $0 <= t }
            handle(g.tick(at: t), t)
            switch e {
            case "down": handle(g.fnDown(at: t), t)
            case "up": handle(g.fnUp(at: t), t)
            case "key": handle(g.otherKeyDown(at: t), t)
            default: break  // "tick" only
            }
        }
        return out
    }

    func testHoldPlaysStartAtTheThresholdAndStopOnRelease() {
        XCTAssertEqual(heard([(0, "down"), (2, "up")]), [.start, .stop])
    }

    // The short-press hint covers a tap; a start sound there would announce a recording that never happens.
    func testTooShortTapIsSilent() {
        XCTAssertEqual(heard([(0, "down"), (0.2, "up"), (1, "tick")]), [])
    }

    // fn used as a modifier (fn+Delete is forward delete) must not chime on every shortcut.
    func testFnShortcutIsSilent() {
        XCTAssertEqual(heard([(0, "down"), (0.1, "key"), (0.3, "up"), (1, "tick")]), [])
    }

    // A shortcut after the start sound was heard ends with the cancel sound.
    func testCancelAfterAHeardStartPlaysCancel() {
        XCTAssertEqual(heard([(0, "down"), (0.7, "key"), (0.8, "up")]), [.start, .cancel])
    }

    func testDoubleTapPlaysLockThenStop() {
        XCTAssertEqual(heard([(0, "down"), (0.1, "up"), (0.3, "down"), (0.4, "up"), (5, "down")]), [.lock, .stop])
    }

    private func crossings(_ s: ArraySlice<Float>) -> Int {
        zip(s, s.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }
}
