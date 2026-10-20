import XCTest
@testable import ShepetalCore

final class MicAudioTests: XCTestCase {
    // An fn event is timed by when the key moved: an event read 0.6 s late keeps its own time.
    func testEventTimeIsWhenTheKeyMoved() {
        let now: TimeInterval = 1000
        XCTAssertEqual(FnClock.seconds(timestamp: 999_400_000_000, now: now), 999.4, accuracy: 1e-9)
        XCTAssertEqual(FnClock.seconds(timestamp: 1_000_000_000_000, now: now), now, accuracy: 1e-9)
        // No timestamp (a synthesized event), one from the future, or a stale one: use the read time.
        XCTAssertEqual(FnClock.seconds(timestamp: 0, now: now), now)
        XCTAssertEqual(FnClock.seconds(timestamp: 1_002_000_000_000, now: now), now)
        XCTAssertEqual(FnClock.seconds(timestamp: 900_000_000_000, now: now), now)
    }

    // Parakeet refuses under 300 ms. Trailing zeros fill the rest; the samples themselves are kept as they are.
    func testPaddingKeepsTheSamplesAndOnlyAppendsZeros() {
        let short: [Float] = [0.1, -0.2, 0.3]
        let padded = MicAudio.padded(short, to: 4800)
        XCTAssertEqual(padded.count, 4800)
        XCTAssertEqual(Array(padded.prefix(3)), short)
        XCTAssertTrue(padded.dropFirst(3).allSatisfy { $0 == 0 })
        let long = [Float](repeating: 0.5, count: 5000)
        XCTAssertEqual(MicAudio.padded(long, to: 4800), long, "long enough audio is untouched")
    }
}
