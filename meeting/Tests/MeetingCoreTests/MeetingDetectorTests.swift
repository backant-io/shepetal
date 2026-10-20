import Testing
@testable import MeetingCore

// Defaults mirror docs/re/meetings.md: grace 5 s, holdoff 10 s, min session 15 s,
// end 3 s bound (clamped to the 4 s reacquire) / 30 s unbound, device change 10 s.

let zoom = MicClient(bundleID: "us.zoom.xos", name: "zoom.us")
let teams = MicClient(bundleID: "com.microsoft.teams2", name: "Microsoft Teams")
let slack = MicClient(bundleID: "com.tinyspeck.slackmacgap.helper", name: "Slack Helper")
let chromeHelper = MicClient(bundleID: "com.google.Chrome.helper", name: "Google Chrome Helper")
let shepetal = MicClient(bundleID: "io.backant.shepetal", name: "shepetal")
let released = Snapshot()
let meetTab = ["com.google.Chrome": ["Meet - abc-defg-hij - Google Chrome"]]

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
    // The probe's wake marker changes after wake or a coreaudiod restart; mic holders right
    // after that are apps reopening audio, not a new call.
    var d = MeetingDetector()
    _ = d.update(Snapshot(wakeMarker: "before sleep"), now: 0)
    let woke = Snapshot(micClients: [zoom], wakeMarker: "after wake")
    #expect(run(&d, woke, from: 1, to: 10).isEmpty)
    #expect(d.update(woke, now: 11) == [.started(app: "Zoom")])
}

@Test func nativeReleaseEndsAfterReacquireWindow() {
    // A native app letting go of the mic is trusted end evidence (bound session): 3 s,
    // clamped to the 4 s reacquire window, not the 30 s unbound wait.
    var d = MeetingDetector()
    _ = run(&d, Snapshot(micClients: [zoom]), from: 0, to: 30)
    #expect(run(&d, released, from: 31, to: 34).isEmpty)
    #expect(d.update(released, now: 35) == [.ended(app: "Zoom")])

    // Mic back within 4 s: same meeting, no end, no new start.
    var d2 = MeetingDetector()
    _ = run(&d2, Snapshot(micClients: [zoom]), from: 0, to: 30)
    var events = run(&d2, released, from: 31, to: 33)
    events += run(&d2, Snapshot(micClients: [zoom]), from: 34, to: 49)
    #expect(events.isEmpty)
    // The next real release gets the full wait again, not the stale time from 31 s.
    #expect(run(&d2, released, from: 50, to: 53).isEmpty)
    #expect(d2.update(released, now: 54) == [.ended(app: "Zoom")])
}

@Test func browserDropWithTabStillOpenWaitsThirtySeconds() {
    // Chrome released the mic but the Meet tab is still there (unbound): wait 30 s.
    var d = MeetingDetector()
    _ = run(&d, Snapshot(micClients: [chromeHelper], windowTitles: meetTab), from: 0, to: 30)
    let tabOpen = Snapshot(windowTitles: meetTab)
    #expect(run(&d, tabOpen, from: 31, to: 60).isEmpty)
    #expect(d.update(tabOpen, now: 61) == [.ended(app: "Google Meet (Chrome)")])

    // Tab closed too (bound): the short wait.
    var d2 = MeetingDetector()
    _ = run(&d2, Snapshot(micClients: [chromeHelper], windowTitles: meetTab), from: 0, to: 30)
    #expect(run(&d2, released, from: 31, to: 34).isEmpty)
    #expect(d2.update(released, now: 35) == [.ended(app: "Google Meet (Chrome)")])
}

@Test func switchingTabsDoesNotEndBrowserMeeting() {
    // CGWindowList only shows the front tab. While Chrome keeps the mic the call goes on.
    var d = MeetingDetector()
    #expect(run(&d, Snapshot(micClients: [chromeHelper], windowTitles: meetTab), from: 0, to: 30)
        == [.started(app: "Google Meet (Chrome)")])
    let docs = Snapshot(micClients: [chromeHelper],
                        windowTitles: ["com.google.Chrome": ["Q3 plan - Google Docs - Google Chrome"]])
    #expect(run(&d, docs, from: 31, to: 61).isEmpty)
    #expect(run(&d, Snapshot(micClients: [chromeHelper], windowTitles: meetTab), from: 62, to: 70).isEmpty)
    #expect(d.active == ["Google Meet (Chrome)"])
}

@Test func noEndInFirstFifteenSeconds() {
    var d = MeetingDetector()
    #expect(run(&d, Snapshot(micClients: [zoom]), from: 0, to: 5) == [.started(app: "Zoom")])
    #expect(run(&d, released, from: 6, to: 19).isEmpty)  // session 14 s old
    #expect(d.update(released, now: 20) == [.ended(app: "Zoom")])
}

@Test func deviceChangeIsNotAnEnd() {
    // Switching to AirPods changes the default devices and can drop the mic for a moment.
    var d = MeetingDetector()
    _ = run(&d, Snapshot(micClients: [zoom], devices: [1, 2]), from: 0, to: 30)
    let airPods = Snapshot(devices: [7, 7])
    #expect(run(&d, airPods, from: 31, to: 40).isEmpty)  // would end at 35 without the change
    #expect(d.update(airPods, now: 41) == [.ended(app: "Zoom")])
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
    #expect(run(&d, Snapshot(micClients: [teams]), from: 31, to: 35) == [.ended(app: "Zoom")])
    #expect(d.active == ["Microsoft Teams"])
    #expect(run(&d, released, from: 36, to: 40) == [.ended(app: "Microsoft Teams")])

    // End evidence is per app: Zoom's release ends Zoom fast while the Meet tab that is still
    // open keeps Meet on the 30 s wait.
    var d2 = MeetingDetector()
    #expect(run(&d2, Snapshot(micClients: [zoom, chromeHelper], windowTitles: meetTab), from: 0, to: 30)
        == [.started(app: "Google Meet (Chrome)"), .started(app: "Zoom")])
    let tabOpen = Snapshot(windowTitles: meetTab)
    #expect(run(&d2, tabOpen, from: 31, to: 35) == [.ended(app: "Zoom")])
    #expect(run(&d2, tabOpen, from: 36, to: 61) == [.ended(app: "Google Meet (Chrome)")])
}

@Test func knownAppsMatchCaseInsensitiveBundleIDsAndWebTitles() {
    let d = MeetingDetector()
    func apps(_ c: MicClient, _ titles: [String] = []) -> Set<String> {
        d.meetingApps(in: Snapshot(micClients: [c], windowTitles: ["com.google.Chrome": titles]))
    }
    // FaceTime reports a lowercase bundle ID; FaceTime audio calls run in avconferenced.
    #expect(apps(MicClient(bundleID: "com.apple.facetime", name: "FaceTime")) == ["FaceTime"])
    #expect(apps(MicClient(bundleID: "com.apple.avconferenced", name: "avconferenced")) == ["FaceTime"])
    #expect(apps(chromeHelper, ["Zoom Meeting - Google Chrome"]) == ["Zoom (Chrome)"])
    #expect(apps(chromeHelper, ["app.zoom.us/wc/123/join - Google Chrome"]) == ["Zoom (Chrome)"])
    #expect(apps(chromeHelper, ["Meet – abc-defg-hij - Google Chrome"]) == ["Google Meet (Chrome)"])
}

@Test func calendarEventIsTheOneAroundNow() {
    let standup = CalendarEvent(title: "Standup", start: 1000, end: 1900)
    let vacation = CalendarEvent(title: "Vacation", start: 0, end: 86_400, isAllDay: true)
    // All-day events never count, or every mic use that day would be a meeting.
    #expect(CalendarEvent.current(in: [vacation], now: 1200) == nil)
    #expect(CalendarEvent.current(in: [vacation, standup], now: 1200) == "Standup")
    // Within 5 min before the start or after the end (overrun) still counts, not later.
    #expect(CalendarEvent.current(in: [standup], now: 700) == "Standup")
    #expect(CalendarEvent.current(in: [standup], now: 2200) == "Standup")
    #expect(CalendarEvent.current(in: [standup], now: 699) == nil)
    #expect(CalendarEvent.current(in: [standup], now: 2201) == nil)
    // Back to back: the one starting nearest to now.
    let retro = CalendarEvent(title: "Retro", start: 1900, end: 2800)
    #expect(CalendarEvent.current(in: [standup, retro], now: 1850) == "Retro")
}

// Mic holders as macOS reports them: Core Audio's kAudioProcessPropertyBundleID, the proc_pidpath
// name, and NSRunningApplication for window owners. Zoom 7.1.9 and Chrome 155 IDs are from their
// Info.plists. Chromium browsers capture in "<app>.helper"; Safari in the WebKit GPU process;
// Firefox in the parent process (cubeb runs behind AudioIPC there, dom/media/CubebUtils.cpp).

@Test func zoomMeetingHelpersAreZoom() {
    let cptHost = MicClient(bundleID: "us.zoom.CptHost", name: "CptHost")
    let aomHost = MicClient(bundleID: "us.zoom.aomhost", name: "aomhost")
    let capHost = MicClient(bundleID: "us.zoom.caphost", name: "caphost")
    let d = MeetingDetector()
    for c in [zoom, cptHost, aomHost, capHost] {
        #expect(d.meetingApps(in: Snapshot(micClients: [c])) == ["Zoom"], "\(c.bundleID)")
    }
    // Not every Zoom process is a call: Clips records a video message.
    #expect(d.meetingApps(in: Snapshot(micClients: [MicClient(bundleID: "us.zoom.ZoomClips", name: "ZoomClips")])).isEmpty)

    // The mic moving between zoom.us and its helpers mid-call is one meeting, ended by the release.
    var d2 = MeetingDetector()
    #expect(run(&d2, Snapshot(micClients: [zoom, cptHost]), from: 0, to: 30) == [.started(app: "Zoom")])
    #expect(run(&d2, Snapshot(micClients: [aomHost]), from: 31, to: 60).isEmpty)
    #expect(run(&d2, released, from: 61, to: 65) == [.ended(app: "Zoom")])
}

@Test func meetIsFoundInEachBrowserFromItsMicHelper() {
    // (mic holder, window owner, front window title, browser)
    let cases: [(MicClient, String, String, String)] = [
        (chromeHelper, "com.google.Chrome", "Meet - abc-defg-hij - Google Chrome", "Chrome"),
        (MicClient(bundleID: "com.apple.WebKit.GPU", name: "com.apple.WebKit.GPU"),
         "com.apple.Safari", "Meet - abc-defg-hij", "Safari"),
        (MicClient(bundleID: "company.thebrowser.browser.helper", name: "Browser Helper"),
         "company.thebrowser.Browser", "Meet - abc-defg-hij", "Arc"),
        (MicClient(bundleID: "com.microsoft.edgemac.helper", name: "Microsoft Edge Helper"),
         "com.microsoft.edgemac", "Meet - abc-defg-hij - Work - Microsoft Edge", "Edge"),
        (MicClient(bundleID: "org.mozilla.firefox", name: "firefox"),
         "org.mozilla.firefox", "Meet – abc-defg-hij — Mozilla Firefox", "Firefox"),
    ]
    for (holder, owner, title, browser) in cases {
        var d = MeetingDetector()
        // Other mic use in the same browser (a voice note in Gmail) is not a meeting...
        #expect(run(&d, Snapshot(micClients: [holder], windowTitles: [owner: ["Inbox - Gmail"]]), from: 0, to: 30).isEmpty, "\(browser)")
        // ...the Meet tab is, about 5 s after it shows.
        #expect(run(&d, Snapshot(micClients: [holder], windowTitles: [owner: [title]]), from: 31, to: 36)
            == [.started(app: "Google Meet (\(browser))")], "\(browser)")
        // A Meet tab in another browser does not turn this browser's mic use into a meeting.
        let other = cases.first { $0.1 != owner }!
        #expect(MeetingDetector().meetingApps(in: Snapshot(micClients: [holder], windowTitles: [other.1: [other.2]])).isEmpty, "\(browser)")
    }
}
