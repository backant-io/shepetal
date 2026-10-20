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

    func testActionToSoundMapping() {
        XCTAssertEqual(Chime(.start), .start)
        XCTAssertEqual(Chime(.stop), .stop)
        XCTAssertEqual(Chime(.lockHandsFree), .lock)
        XCTAssertEqual(Chime(.cancel), .cancel)
        XCTAssertNil(Chime(.tooShort), "the short-press hint covers it")
    }

    private func crossings(_ s: ArraySlice<Float>) -> Int {
        zip(s, s.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }
}
