import XCTest
@testable import ShepetalCore

/// Which mic a dictation records from (F07). The choice runs on every mic open, so a wrong rule
/// records from the wrong device, or from a closed lid's built-in mic, without the user noticing.
final class MicTests: XCTestCase {
    let builtIn = MicDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    let usb = MicDevice(uid: "usb-1", name: "Desk USB Mic", transport: .usb)
    let airpods = MicDevice(uid: "bt-1", name: "AirPods", transport: .bluetooth)
    var all: [MicDevice] { [builtIn, usb, airpods] }

    func pick(_ devices: [MicDevice], forced: String? = nil, ranking: [String] = [], lidClosed: Bool = false) throws -> MicDevice {
        try MicChoice.pick(devices, forced: forced, ranking: ranking, systemDefault: builtIn.uid, lidClosed: lidClosed)
    }

    func testForcedDeviceWins() throws {
        XCTAssertEqual(try pick(all, forced: airpods.uid, ranking: [usb.uid]), airpods)
    }

    func testForcedDeviceMissingFallsBackToRanking() throws {
        XCTAssertEqual(try pick([builtIn, usb], forced: airpods.uid, ranking: [usb.uid]), usb)
    }

    func testRankingOrderPicksFirstPresent() throws {
        let ranking = ["unplugged", airpods.uid, usb.uid]
        XCTAssertEqual(try pick(all, ranking: ranking), airpods)
        XCTAssertEqual(try pick([builtIn, usb], ranking: ranking), usb)
    }

    func testNothingRankedUsesSystemDefault() throws {
        XCTAssertEqual(try pick([usb, builtIn], ranking: ["unplugged"]), builtIn)
        XCTAssertEqual(try MicChoice.pick(all, forced: nil, ranking: [], systemDefault: usb.uid, lidClosed: false), usb)
    }

    func testClamshellSkipsBuiltIn() throws {
        // The system default and the forced device are both the built-in mic, which a closed lid covers.
        XCTAssertEqual(try pick([builtIn, usb], forced: builtIn.uid, ranking: [builtIn.uid], lidClosed: true), usb)
        XCTAssertEqual(try pick([builtIn, usb], lidClosed: true), usb)
        XCTAssertEqual(try pick([builtIn, usb], lidClosed: false), builtIn)
        let loopback = MicDevice(uid: "loop", name: "Meeting App Audio", transport: .virtual)
        XCTAssertEqual(try pick([builtIn, loopback, usb], lidClosed: true), usb, "a loopback driver records no voice")
        XCTAssertEqual(try pick([builtIn, loopback], lidClosed: true), loopback)
    }

    func testClamshellWithOnlyBuiltInIsAnError() {
        XCTAssertThrowsError(try pick([builtIn], lidClosed: true)) { XCTAssertEqual($0 as? MicError, .lidClosed) }
        XCTAssertThrowsError(try pick([], lidClosed: false)) { XCTAssertEqual($0 as? MicError, .noMic) }
    }

    func testPreferMovesToTop() throws {
        let ranking = MicChoice.prefer(airpods.uid, in: [usb.uid, airpods.uid, "old"])
        XCTAssertEqual(ranking, [airpods.uid, usb.uid, "old"])
        XCTAssertEqual(MicChoice.prefer("new", in: ranking), ["new", airpods.uid, usb.uid, "old"])
        XCTAssertEqual(try pick(all, ranking: ranking), airpods)
    }

    func testNewDeviceNoticedOnce() {
        var notices = MicNotices(seen: nil, bluetoothHintShown: false)
        // What is plugged in at the first look is not new.
        XCTAssertEqual(notices.update([builtIn, usb], pick: builtIn), [])
        XCTAssertEqual(notices.update([builtIn, usb, airpods], pick: builtIn), ["New mic: AirPods"])
        XCTAssertEqual(notices.update([builtIn, usb, airpods], pick: builtIn), [])
        XCTAssertEqual(notices.update([builtIn, usb], pick: builtIn), [])                       // unplugged
        XCTAssertEqual(notices.update([builtIn, usb, airpods], pick: builtIn), [])              // replugged: seen before
        XCTAssertEqual(notices.update([builtIn, usb, airpods], pick: airpods), ["Using AirPods"])  // automatic switch
        XCTAssertEqual(notices.update([builtIn, usb, airpods], pick: airpods), [])

        // The seen set survives a relaunch.
        var relaunched = MicNotices(seen: notices.seen, bluetoothHintShown: false)
        let headset = MicDevice(uid: "usb-2", name: "Headset", transport: .usb)
        XCTAssertEqual(relaunched.update([builtIn, usb, headset], pick: builtIn), ["New mic: Headset"])
    }

    // MARK: health (F08)

    /// Feeds 0.1 s buffers from `from` to `to` (seconds after the start at 0) and collects the events.
    func feed(_ health: inout MicHealth, zeros: Bool, from: Double, to: Double) -> [MicHealth.Event] {
        var events: [MicHealth.Event] = []
        let first = Int((from * 10).rounded()), last = Int((to * 10).rounded())
        for tenth in first...last {  // whole tenths, so 5.0 is exactly 5.0
            events += health.buffer([Float](repeating: zeros ? 0 : 0.1, count: 1600), at: Double(tenth) / 10)
        }
        return events
    }

    func testFiveSecondsOfZerosWarnsOnce() {
        var h = MicHealth(start: 0)
        _ = feed(&h, zeros: false, from: 0.1, to: 1)
        XCTAssertEqual(feed(&h, zeros: true, from: 1.1, to: 6.0), [])       // 4.9 s of zeros
        XCTAssertEqual(feed(&h, zeros: true, from: 6.1, to: 6.2), [.silent])  // 5 s
        XCTAssertEqual(feed(&h, zeros: true, from: 6.3, to: 12), [])
    }

    func testRealAudioResetsTheSilenceCount() {
        var h = MicHealth(start: 0)
        _ = feed(&h, zeros: false, from: 0.1, to: 0.5)
        XCTAssertEqual(feed(&h, zeros: true, from: 0.6, to: 4.6), [])
        XCTAssertEqual(feed(&h, zeros: false, from: 4.7, to: 4.7), [])
        XCTAssertEqual(feed(&h, zeros: true, from: 4.8, to: 9.7), [])        // 4.9 s since the reset
        XCTAssertEqual(feed(&h, zeros: true, from: 9.8, to: 9.8), [.silent])
    }

    func testFifteenSecondsEscalates() {
        var h = MicHealth(start: 0)
        _ = feed(&h, zeros: false, from: 0.1, to: 1)
        let events = feed(&h, zeros: true, from: 1.1, to: 15.9)
        XCTAssertEqual(events, [.silent])
        XCTAssertEqual(feed(&h, zeros: true, from: 16.0, to: 16.1), [.stillSilent])
        XCTAssertEqual(feed(&h, zeros: true, from: 16.2, to: 30), [])
    }

    func testNoBuffersInFiveSecondsStops() {
        var h = MicHealth(start: 100)
        XCTAssertEqual(h.tick(at: 104.9), [])
        XCTAssertEqual(h.tick(at: 105), [.noAudio])
        XCTAssertEqual(h.tick(at: 106), [])  // once

        var flowing = MicHealth(start: 100)
        _ = flowing.buffer([0.1], at: 100.1)
        XCTAssertEqual(flowing.tick(at: 110), [], "buffers came, so it is not a stop")
    }

    func testSilentStartReopensOnce() {
        var h = MicHealth(start: 0)
        XCTAssertEqual(feed(&h, zeros: true, from: 0.1, to: 0.9), [])
        XCTAssertEqual(feed(&h, zeros: true, from: 1.0, to: 1.0), [.reopen])
        // After the reopen the zeros go on: the warning still comes at 5 s, and no second reopen.
        XCTAssertEqual(feed(&h, zeros: true, from: 1.1, to: 5.0), [.silent])

        var talking = MicHealth(start: 0)
        _ = feed(&talking, zeros: false, from: 0.1, to: 0.5)
        XCTAssertFalse(feed(&talking, zeros: true, from: 0.6, to: 4).contains(.reopen), "only a silent start reopens")
    }

    func testBluetoothHintOnce() {
        var notices = MicNotices(seen: nil, bluetoothHintShown: false)
        XCTAssertNil(notices.opening(usb, builtInUsable: true))
        XCTAssertNil(notices.opening(airpods, builtInUsable: false), "no built-in mic to suggest (lid closed, desktop)")
        XCTAssertEqual(notices.opening(airpods, builtInUsable: true), MicNotices.bluetoothHint)
        XCTAssertNil(notices.opening(airpods, builtInUsable: true))
        var relaunched = MicNotices(seen: nil, bluetoothHintShown: notices.bluetoothHintShown)
        XCTAssertNil(relaunched.opening(airpods, builtInUsable: true))
    }

    func testQuietRecordingSuggestsCloserMic() {
        let speech = (0..<16_000).map { Float(sin(Double($0) / 8)) * 0.05 }  // about -29 dBFS
        let far = speech.map { $0 / 30 }                                       // about -59 dBFS
        XCTAssertFalse(MicHealth.isQuiet(speech))
        XCTAssertTrue(MicHealth.isQuiet(far))
        XCTAssertFalse(MicHealth.isQuiet([Float](repeating: 0, count: 16_000)), "a dead mic gets its own warning")
        XCTAssertFalse(MicHealth.isQuiet([]))
        XCTAssertFalse(MicHealth.isQuiet(far, floor: 0.0005), "the floor is a knob")
    }
}
