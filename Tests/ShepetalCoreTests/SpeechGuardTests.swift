import XCTest
@testable import ShepetalCore

/// F51: silence and the tags models print for it must never become pasted text.
final class SpeechGuardTests: XCTestCase {
    func tone(db: Float, seconds: Float = 1) -> [Float] {
        let amp = Float(2).squareRoot() * pow(10, db / 20)
        return (0..<Int(seconds * 16_000)).map { amp * sin(2 * .pi * 440 * Float($0) / 16_000) }
    }

    func noise(db: Float, count: Int = 16_000) -> [Float] {
        var x: UInt32 = 1
        let raw = (0..<count).map { _ -> Float in
            x = x &* 1_664_525 &+ 1_013_904_223
            return Float(x) / Float(UInt32.max) - 0.5
        }
        let rms = (raw.reduce(0) { $0 + $1 * $1 } / Float(count)).squareRoot()
        return raw.map { $0 * pow(10, db / 20) / rms }
    }

    func testLevelOfSilenceNoiseAndToneAgainstTheFloor() {
        XCTAssertEqual(SpeechGuard.floorDb, -60)
        XCTAssertEqual(SpeechGuard.levelDb([Float](repeating: 0, count: 16_000)), -.infinity)
        XCTAssertEqual(SpeechGuard.levelDb([]), -.infinity)
        XCTAssertFalse(SpeechGuard.isSpeech([Float](repeating: 0, count: 16_000)))

        XCTAssertEqual(SpeechGuard.levelDb(noise(db: -70)), -70, accuracy: 1)
        XCTAssertFalse(SpeechGuard.isSpeech(noise(db: -70)), "room noise is not speech")

        XCTAssertEqual(SpeechGuard.levelDb(tone(db: -30)), -30, accuracy: 0.05)
        XCTAssertTrue(SpeechGuard.isSpeech(tone(db: -30)))
        XCTAssertTrue(SpeechGuard.isSpeech(tone(db: -59)))
        XCTAssertFalse(SpeechGuard.isSpeech(tone(db: -61)))
    }

    // A whole-recording RMS would put this at about -66 dBFS and drop the word.
    func testShortQuietWordInALongRecordingIsSpeech() {
        let word = tone(db: -45, seconds: 0.5)
        let recording = [Float](repeating: 0, count: 30 * 16_000) + word + [Float](repeating: 0, count: 30 * 16_000)
        XCTAssertTrue(SpeechGuard.isSpeech(recording))
    }

    func testFloorIsAUserDefaultsKnob() {
        // The registration domain lives in memory only; put it back so later tests see the code default.
        let d = UserDefaults.standard
        let saved = d.volatileDomain(forName: UserDefaults.registrationDomain)
        d.register(defaults: ["speechFloorDb": -20])
        defer { d.setVolatileDomain(saved, forName: UserDefaults.registrationDomain) }
        XCTAssertEqual(SpeechGuard.floorDb, -20)
        XCTAssertFalse(SpeechGuard.isSpeech(tone(db: -30)))
    }

    func testStripsNonSpeechTags() {
        XCTAssertEqual(SpeechGuard.stripTags("[BLANK_AUDIO]"), "")
        XCTAssertEqual(SpeechGuard.stripTags("[BLANK_AUDIO] hello"), "hello")
        XCTAssertEqual(SpeechGuard.stripTags(" (silence) "), "")
        XCTAssertEqual(SpeechGuard.stripTags("[Music] [ Silence ]"), "")
        XCTAssertEqual(SpeechGuard.stripTags("(upbeat music)"), "")
        XCTAssertEqual(SpeechGuard.stripTags("See the chart (page 2)."), "See the chart (page 2).", "dictated parentheses stay")
        XCTAssertEqual(SpeechGuard.stripTags("Send it today."), "Send it today.")
    }
}
