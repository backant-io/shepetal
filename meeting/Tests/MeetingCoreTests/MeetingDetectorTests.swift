import Testing
@testable import MeetingCore

let zoom = MicClient(bundleID: "us.zoom.xos", name: "zoom.us")
let teams = MicClient(bundleID: "com.microsoft.teams2", name: "Microsoft Teams")
let chromeHelper = MicClient(bundleID: "com.google.Chrome.helper", name: "Google Chrome Helper")
let shepetal = MicClient(bundleID: "io.backant.shepetal", name: "shepetal")

/// Feeds the same snapshot once per second over [from, to] and collects events.
func run(_ d: inout MeetingDetector, _ s: Snapshot, from: Int, to: Int) -> [MeetingEvent] {
    (from...to).flatMap { d.update(s, now: Double($0)) }
}

@Test func startsOnlyAfterStartThreshold() {
    var d = MeetingDetector(startAfter: 5, endAfter: 10)
    let s = Snapshot(micClients: [zoom])
    #expect(run(&d, s, from: 0, to: 4).isEmpty)  // 4 s held: too short
    #expect(d.update(s, now: 5) == [.started(app: "Zoom")])
    #expect(run(&d, s, from: 6, to: 20).isEmpty)  // no duplicate start
}

@Test func endsOnlyAfterEndThreshold() {
    var d = MeetingDetector(startAfter: 5, endAfter: 10)
    _ = run(&d, Snapshot(micClients: [zoom]), from: 0, to: 5)
    #expect(run(&d, Snapshot(), from: 6, to: 15).isEmpty)  // released 9 s
    #expect(d.update(Snapshot(), now: 16) == [.ended(app: "Zoom")])
    #expect(d.active.isEmpty)
}

@Test func flappingMicDoesNotStartOrEnd() {
    var d = MeetingDetector(startAfter: 5, endAfter: 10)
    // Mic toggles every 2 s: never held 5 s in a row, so no meeting.
    var events: [MeetingEvent] = []
    for t in 0..<30 { events += d.update(Snapshot(micClients: t % 4 < 2 ? [zoom] : []), now: Double(t)) }
    #expect(events.isEmpty)

    // Once started, short mutes (< endAfter) must not end the meeting.
    _ = run(&d, Snapshot(micClients: [zoom]), from: 30, to: 35)
    #expect(d.active == ["Zoom"])
    for t in 36..<80 { events += d.update(Snapshot(micClients: t % 10 < 5 ? [] : [zoom]), now: Double(t)) }
    #expect(events.isEmpty)
}

@Test func browserMeetingMatchedByWindowTitle() {
    var d = MeetingDetector(startAfter: 2, endAfter: 2)
    let meet = Snapshot(micClients: [chromeHelper], windowTitles: ["com.google.Chrome": ["Meet - abc-defg-hij"]])
    #expect(run(&d, meet, from: 0, to: 2) == [.started(app: "Google Meet (Chrome)")])

    // Safari's mic is held by the WebKit GPU process, its windows belong to Safari.
    var ds = MeetingDetector(startAfter: 2, endAfter: 2)
    let safari = Snapshot(micClients: [MicClient(bundleID: "com.apple.WebKit.GPU", name: "com.apple.WebKit.GPU")],
                          windowTitles: ["com.apple.Safari": ["Weekly sync | Microsoft Teams"]])
    #expect(run(&ds, safari, from: 0, to: 2) == [.started(app: "Microsoft Teams (Safari)")])

    // Browser mic without a meeting tab (e.g. a voice memo site) is not a meeting.
    var d2 = MeetingDetector(startAfter: 2, endAfter: 2)
    let other = Snapshot(micClients: [chromeHelper], windowTitles: ["com.google.Chrome": ["Inbox - Gmail"]])
    #expect(run(&d2, other, from: 0, to: 10).isEmpty)
}

@Test func shepetalDictationIsNeverAMeeting() {
    var d = MeetingDetector(startAfter: 1, endAfter: 1)
    // Even during a calendar event, where unknown mic users do count.
    let s = Snapshot(micClients: [shepetal, MicClient(bundleID: "dev.shepetal.helper", name: "Shepetal Helper")],
                     calendarEvent: "Standup")
    #expect(run(&d, s, from: 0, to: 60).isEmpty)
    let other = MicClient(bundleID: "com.example.voip", name: "VoIP")
    #expect(run(&d, Snapshot(micClients: [other], calendarEvent: "Standup"), from: 61, to: 62)
        == [.started(app: "VoIP: Standup")])
}

@Test func twoAppsAtOnceAreTrackedIndependently() {
    var d = MeetingDetector(startAfter: 3, endAfter: 3)
    #expect(run(&d, Snapshot(micClients: [zoom]), from: 0, to: 3) == [.started(app: "Zoom")])
    #expect(run(&d, Snapshot(micClients: [zoom, teams]), from: 4, to: 7) == [.started(app: "Microsoft Teams")])
    // Zoom leaves; Teams keeps going.
    #expect(run(&d, Snapshot(micClients: [teams]), from: 8, to: 11) == [.ended(app: "Zoom")])
    #expect(d.active == ["Microsoft Teams"])
    #expect(run(&d, Snapshot(), from: 12, to: 15) == [.ended(app: "Microsoft Teams")])
}
