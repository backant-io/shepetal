import Testing
@testable import MeetingCore

// Defaults mirror docs/re/meetings.md: grace 5 s, holdoff 10 s, min session 15 s,
// end 3 s with evidence / 30 s without, reacquire 4 s, device change 10 s.

let zoom = MicClient(bundleID: "us.zoom.xos", name: "zoom.us")
let teams = MicClient(bundleID: "com.microsoft.teams2", name: "Microsoft Teams")
let slack = MicClient(bundleID: "com.tinyspeck.slackmacgap.helper", name: "Slack Helper")
let chromeHelper = MicClient(bundleID: "com.google.Chrome.helper", name: "Google Chrome Helper")
let shepetal = MicClient(bundleID: "io.backant.shepetal", name: "shepetal")
let released = Snapshot()
var gone: Snapshot { var s = Snapshot(); s.meetingWindowGone = true; return s }

/// Feeds the same snapshot once per second over [from, to] and collects events.
func run(_ d: inout MeetingDetector, _ s: Snapshot, from: Int, to: Int) -> [MeetingEvent] {
    (from...to).flatMap { d.update(s, now: Double($0)) }
}

@Test func startsAfterFiveSecondGrace() {
    var d = MeetingDetector()
    let s = Snapshot(micClients: [zoom])
    #expect(run(&d, s, from: 0, to: 4).isEmpty)
    #expect(d.update(s, now: 5) == [.started(app: "Zoom")])
    #expect(run(&d, s, from: 6, to: 20).isEmpty)  // no duplicate start
}

@Test func noStartDuringTenSecondHoldoffAfterWake() {
    var d = MeetingDetector()
    d.wokeOrAudioRestarted(now: 0)
    #expect(run(&d, Snapshot(micClients: [zoom]), from: 0, to: 9).isEmpty)
    #expect(d.update(Snapshot(micClients: [zoom]), now: 10) == [.started(app: "Zoom")])
}

@Test func endWaitsThirtySecondsWithoutEvidence() {
    var d = MeetingDetector()
    _ = run(&d, Snapshot(micClients: [zoom]), from: 0, to: 30)  // started at 5
    #expect(run(&d, released, from: 31, to: 60).isEmpty)  // released 29 s
    #expect(d.update(released, now: 61) == [.ended(app: "Zoom")])
}

@Test func endWithEvidenceRespectsReacquireWindow() {
    var d = MeetingDetector()
    _ = run(&d, Snapshot(micClients: [zoom]), from: 0, to: 30)
    // Evidence says 3 s, but the mic may come back within 4 s: end at 4 s.
    #expect(run(&d, gone, from: 31, to: 34).isEmpty)
    #expect(d.update(gone, now: 35) == [.ended(app: "Zoom")])

    // Mic back within 4 s: same meeting, no end, no new start.
    var d2 = MeetingDetector()
    _ = run(&d2, Snapshot(micClients: [zoom]), from: 0, to: 30)
    var events = run(&d2, gone, from: 31, to: 33)
    events += run(&d2, Snapshot(micClients: [zoom]), from: 34, to: 50)
    #expect(events.isEmpty)
}

@Test func noEndInFirstFifteenSeconds() {
    var d = MeetingDetector()
    #expect(run(&d, Snapshot(micClients: [zoom]), from: 0, to: 5) == [.started(app: "Zoom")])
    #expect(run(&d, gone, from: 6, to: 19).isEmpty)  // session 14 s old
    #expect(d.update(gone, now: 20) == [.ended(app: "Zoom")])
}

@Test func deviceChangeIsNotAnEnd() {
    var d = MeetingDetector()
    _ = run(&d, Snapshot(micClients: [zoom]), from: 0, to: 30)
    d.deviceChanged(now: 31)
    #expect(run(&d, gone, from: 31, to: 40).isEmpty)  // would end at 35 without the change
    #expect(d.update(gone, now: 41) == [.ended(app: "Zoom")])
}

@Test func flappingMicDoesNotStart() {
    var d = MeetingDetector()
    // Mic toggles every 2 s: never held 5 s in a row.
    var events: [MeetingEvent] = []
    for t in 0..<40 { events += d.update(Snapshot(micClients: t % 4 < 2 ? [zoom] : []), now: Double(t)) }
    #expect(events.isEmpty)
}

@Test func browserNeedsMeetingTab() {
    var d = MeetingDetector()
    let meet = Snapshot(micClients: [chromeHelper], windowTitles: ["com.google.Chrome": ["Meet - abc-defg-hij"]])
    #expect(run(&d, meet, from: 0, to: 5) == [.started(app: "Google Meet (Chrome)")])

    // Safari's mic is held by the WebKit GPU process, its windows belong to Safari.
    var ds = MeetingDetector()
    let safari = Snapshot(micClients: [MicClient(bundleID: "com.apple.WebKit.GPU", name: "com.apple.WebKit.GPU")],
                          windowTitles: ["com.apple.Safari": ["Weekly sync | Microsoft Teams"]])
    #expect(run(&ds, safari, from: 0, to: 5) == [.started(app: "Microsoft Teams (Safari)")])

    var d2 = MeetingDetector()
    let other = Snapshot(micClients: [chromeHelper], windowTitles: ["com.google.Chrome": ["Inbox - Gmail"]])
    #expect(run(&d2, other, from: 0, to: 30).isEmpty)
}

@Test func slackNeedsHuddleEvidence() {
    var d = MeetingDetector()
    #expect(run(&d, Snapshot(micClients: [slack]), from: 0, to: 30).isEmpty)  // e.g. recording a clip
    let channel = Snapshot(micClients: [slack], windowTitles: ["com.tinyspeck.slackmacgap": ["general (Channel) - Acme - Slack"]])
    #expect(run(&d, channel, from: 0, to: 30).isEmpty)
    let huddle = Snapshot(micClients: [slack], windowTitles: ["com.tinyspeck.slackmacgap": ["Huddle in #general"]])
    #expect(run(&d, huddle, from: 31, to: 36) == [.started(app: "Slack")])
}

@Test func shepetalDictationIsNeverAMeeting() {
    var d = MeetingDetector()
    // Even during a calendar event, where unknown mic users do count.
    let s = Snapshot(micClients: [shepetal, MicClient(bundleID: "dev.shepetal.helper", name: "Shepetal Helper")],
                     calendarEvent: "Standup")
    #expect(run(&d, s, from: 0, to: 60).isEmpty)
    let other = MicClient(bundleID: "com.example.voip", name: "VoIP")
    #expect(run(&d, Snapshot(micClients: [other], calendarEvent: "Standup"), from: 61, to: 66)
        == [.started(app: "VoIP: Standup")])
}

@Test func twoAppsAtOnceAreTrackedIndependently() {
    var d = MeetingDetector()
    #expect(run(&d, Snapshot(micClients: [zoom]), from: 0, to: 5) == [.started(app: "Zoom")])
    #expect(run(&d, Snapshot(micClients: [zoom, teams]), from: 6, to: 30) == [.started(app: "Microsoft Teams")])
    var teamsOnly = Snapshot(micClients: [teams]); teamsOnly.meetingWindowGone = true
    #expect(run(&d, teamsOnly, from: 31, to: 35) == [.ended(app: "Zoom")])
    #expect(d.active == ["Microsoft Teams"])
    #expect(run(&d, gone, from: 36, to: 40) == [.ended(app: "Microsoft Teams")])
}
