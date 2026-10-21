import Testing
@testable import MeetingCore

// Pavel's rule (2026-10-21): any other app on the mic or the camera for 5 s is a possible meeting; it ends 4 s
// after both are free, never in its first 15 s and never within 10 s of a device change; no start within 10 s of
// wake. Fixtures are processes as macOS reports them (Core Audio pid and bundle ID, proc_pidpath, the responsible
// process); the paths are from Zoom 7.1.9, Chrome 154, Safari 26 and Firefox installs.

let ownPID: Int32 = 4242
let zoomPath = "/Applications/zoom.us.app/Contents/MacOS/zoom.us"
let zoom = MicUser(pid: 100, bundleID: "us.zoom.xos", path: zoomPath, responsiblePath: zoomPath)
let teams = MicUser(pid: 200, bundleID: "com.microsoft.teams2",
                    path: "/Applications/Microsoft Teams.app/Contents/MacOS/MSTeams")
let chromeHelper = MicUser(
    pid: 300, bundleID: "com.google.Chrome.helper",
    path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/154.0.8037.99/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
    responsiblePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
let released = Snapshot()

func detector() -> MeetingDetector { MeetingDetector(ownPID: ownPID, ownBundleID: "io.backant.shepetal") }

/// Feeds the same snapshot once per second over [from, to] and collects events.
func run(_ d: inout MeetingDetector, _ s: Snapshot, from: Int, to: Int) -> [MeetingEvent] {
    (from...to).flatMap { d.update(s, now: Double($0)) }
}

@Test func anotherAppOnTheMicForFiveSecondsIsAMeeting() {
    var d = detector()
    let s = Snapshot(micUsers: [zoom])
    #expect(run(&d, s, from: 0, to: 4).isEmpty)
    #expect(d.update(s, now: 5) == [.started(app: "zoom.us")])
    #expect(run(&d, s, from: 6, to: 20).isEmpty)  // no duplicate start
}

@Test func anyAppCountsNotOnlyKnownMeetingApps() {
    // No allowlist: an app nobody listed is offered as well, named by its bundle.
    var d = detector()
    let voip = MicUser(pid: 500, bundleID: "com.example.voip", path: "/Applications/Some VoIP.app/Contents/MacOS/voip")
    #expect(run(&d, Snapshot(micUsers: [voip]), from: 0, to: 5) == [.started(app: "Some VoIP")])
}

@Test func theCameraAloneIsAMeetingAndKeepsItGoing() {
    // macOS does not say who runs a camera: the card says "Camera".
    var d = detector()
    let camera = Snapshot(cameraInUse: true)
    #expect(run(&d, camera, from: 0, to: 5) == [.started(app: "Camera")])
    // Mic muted (released) with the camera still on is the same meeting, however long.
    var d2 = detector()
    #expect(run(&d2, Snapshot(micUsers: [zoom], cameraInUse: true), from: 0, to: 30) == [.started(app: "zoom.us")])
    #expect(run(&d2, camera, from: 31, to: 120).isEmpty)
    #expect(run(&d2, released, from: 121, to: 124).isEmpty)
    #expect(d2.update(released, now: 125) == [.ended(app: "zoom.us")], "4 s after both are free")
}

@Test func endsFourSecondsAfterReleaseAndUseBackSoonerIsTheSameMeeting() {
    var d = detector()
    _ = run(&d, Snapshot(micUsers: [zoom]), from: 0, to: 30)
    #expect(run(&d, released, from: 31, to: 34).isEmpty)
    #expect(d.update(released, now: 35) == [.ended(app: "zoom.us")])

    // Mic back within 4 s: same meeting, no end, no new start.
    var d2 = detector()
    _ = run(&d2, Snapshot(micUsers: [zoom]), from: 0, to: 30)
    var events = run(&d2, released, from: 31, to: 33)
    events += run(&d2, Snapshot(cameraInUse: true), from: 34, to: 49)  // the camera takes over
    #expect(events.isEmpty)
    // The next real release gets the full wait again, not the stale time from 31 s.
    #expect(run(&d2, released, from: 50, to: 53).isEmpty)
    #expect(d2.update(released, now: 54) == [.ended(app: "zoom.us")])
}

@Test func noStartDuringTenSecondHoldoffAfterWake() {
    // The probe's wake marker changes after wake or a coreaudiod restart; mic users right
    // after that are apps reopening audio, not a new call.
    var d = detector()
    _ = d.update(Snapshot(wakeMarker: "before sleep"), now: 0)
    let woke = Snapshot(micUsers: [zoom], wakeMarker: "after wake")
    #expect(run(&d, woke, from: 1, to: 10).isEmpty)
    #expect(d.update(woke, now: 11) == [.started(app: "zoom.us")])
}

@Test func noEndInFirstFifteenSeconds() {
    var d = detector()
    #expect(run(&d, Snapshot(micUsers: [zoom]), from: 0, to: 5) == [.started(app: "zoom.us")])
    #expect(run(&d, released, from: 6, to: 19).isEmpty)  // session 14 s old
    #expect(d.update(released, now: 20) == [.ended(app: "zoom.us")])
}

@Test func deviceChangeIsNotAnEnd() {
    // Switching to AirPods changes the default devices and can drop the mic for a moment.
    var d = detector()
    _ = run(&d, Snapshot(micUsers: [zoom], devices: [1, 2]), from: 0, to: 30)
    let airPods = Snapshot(devices: [7, 7])
    #expect(run(&d, airPods, from: 31, to: 40).isEmpty)  // would end at 35 without the change
    #expect(d.update(airPods, now: 41) == [.ended(app: "zoom.us")])
}

@Test func flappingUseDoesNotStart() {
    var d = detector()
    // Mic, then camera, toggling every 2 s: never in use 5 s in a row.
    var events: [MeetingEvent] = []
    for t in 0..<40 {
        let on = t % 4 < 2
        events += d.update(Snapshot(micUsers: on && t < 20 ? [zoom] : [], cameraInUse: on && t >= 20), now: Double(t))
    }
    #expect(events.isEmpty)
}

@Test func shepetalItselfIsExcludedExactlyNeverByName() {
    var d = detector()
    // Our dictation or meeting capture: our pid, or our bundle ID in another instance of the app.
    let ours = MicUser(pid: ownPID, path: "/Applications/Shepetal.app/Contents/MacOS/Shepetal")
    let otherInstance = MicUser(pid: 777, bundleID: "io.backant.shepetal", path: "/Users/p/dist/Shepetal.app/Contents/MacOS/Shepetal")
    #expect(run(&d, Snapshot(micUsers: [ours, otherInstance]), from: 0, to: 60).isEmpty)
    // Someone else's app with "shepetal" in its name or ID is not us.
    let lookalike = MicUser(pid: 778, bundleID: "dev.shepetal.helper", path: "/Applications/Shepetal Helper.app/Contents/MacOS/helper")
    #expect(run(&d, Snapshot(micUsers: [ours, lookalike]), from: 61, to: 66) == [.started(app: "Shepetal Helper")])
    // While we record a meeting, the call app alone keeps it going and ends it.
    var d2 = detector()
    _ = run(&d2, Snapshot(micUsers: [zoom]), from: 0, to: 30)
    #expect(run(&d2, Snapshot(micUsers: [ours]), from: 31, to: 35) == [.ended(app: "zoom.us")])
}

@Test func twoAppsAreOneMeetingUntilBothLetGo() {
    var d = detector()
    #expect(run(&d, Snapshot(micUsers: [zoom]), from: 0, to: 5) == [.started(app: "zoom.us")])
    #expect(run(&d, Snapshot(micUsers: [zoom, teams]), from: 6, to: 30).isEmpty, "no second card")
    #expect(run(&d, Snapshot(micUsers: [teams]), from: 31, to: 60).isEmpty)
    #expect(d.active == "zoom.us")
    #expect(run(&d, released, from: 61, to: 65) == [.ended(app: "zoom.us")])
}

@Test func helpersAreNamedAfterTheirApp() {
    let d = detector()
    func app(_ users: MicUser...) -> String? { d.app(in: Snapshot(micUsers: users)) }
    // A helper bundle inside the app: the outermost .app wins.
    #expect(app(chromeHelper) == "Google Chrome")
    #expect(app(MicUser(pid: 1, bundleID: "us.zoom.CptHost",
                        path: "/Applications/zoom.us.app/Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost")) == "zoom.us")
    // Outside any app (an XPC service, a daemon): the responsible process names it, else the generic label.
    let webkitGPU = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
    #expect(app(MicUser(pid: 2, bundleID: "com.apple.WebKit.GPU", path: webkitGPU,
                        responsiblePath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari")) == "Safari")
    let daemon = MicUser(pid: 3, bundleID: "com.apple.avconferenced", path: "/usr/libexec/avconferenced",
                         responsiblePath: "/usr/libexec/avconferenced")
    #expect(app(daemon) == "Microphone")
    #expect(app(MicUser(pid: 4, path: "")) == "Microphone", "a process that exited between the reads")
    // The first named user names the card.
    #expect(app(daemon, chromeHelper) == "Google Chrome")
    #expect(d.app(in: Snapshot(micUsers: [daemon], cameraInUse: true)) == "Microphone")
    #expect(d.app(in: released) == nil)
}

@Test func meetInEachBrowserIsFoundFromItsMicHelperWithoutWindowTitles() {
    // M-MTG-2: no tab title and no Screen Recording, only the browser's capture process.
    let cases: [(MicUser, String)] = [
        (chromeHelper, "Google Chrome"),
        (MicUser(pid: 11, bundleID: "com.apple.WebKit.GPU",
                 path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
                 responsiblePath: "/Applications/Safari.app/Contents/MacOS/Safari"), "Safari"),
        (MicUser(pid: 12, bundleID: "company.thebrowser.browser.helper",
                 path: "/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper.app/Contents/MacOS/Browser Helper"), "Arc"),
        (MicUser(pid: 13, bundleID: "com.microsoft.edgemac.helper",
                 path: "/Applications/Microsoft Edge.app/Contents/Frameworks/Microsoft Edge Framework.framework/Helpers/Microsoft Edge Helper.app/Contents/MacOS/Microsoft Edge Helper"), "Microsoft Edge"),
        (MicUser(pid: 14, bundleID: "org.mozilla.firefox", path: "/Applications/Firefox.app/Contents/MacOS/firefox"), "Firefox"),
    ]
    for (helper, browser) in cases {
        var d = detector()
        #expect(run(&d, Snapshot(micUsers: [helper]), from: 0, to: 5) == [.started(app: browser)], "\(browser)")
        #expect(run(&d, released, from: 6, to: 20) == [.ended(app: browser)], "\(browser)")
    }
}
