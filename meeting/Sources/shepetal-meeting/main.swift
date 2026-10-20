#if canImport(CoreAudio)
import Foundation
import MeetingCore
import MeetingMac

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "probe":
    let clients = Probes.micClients()
    if clients.isEmpty { print("no process is using the mic") }
    for c in clients { print("\(c.bundleID.isEmpty ? "-" : c.bundleID)\t\(c.name)") }
    let detector = MeetingDetector()
    let snapshot = Probes.snapshot()
    print("calendar event now: \(snapshot.calendarEvent ?? "none (or no Calendar access)")")
    print("meeting apps now: \(detector.meetingApps(in: snapshot).sorted())")
case "watch":
    var detector = MeetingDetector()
    let env = ProcessInfo.processInfo.environment
    detector.startAfter = Double(env["START_AFTER"] ?? "") ?? detector.startAfter
    detector.endWithoutEvidence = Double(env["END_AFTER"] ?? "") ?? detector.endWithoutEvidence
    let bound = max(detector.endWithEvidence, detector.reacquire)
    print("watching (start after \(detector.startAfter)s, end after \(bound)s or \(detector.endWithoutEvidence)s), ctrl-c to stop")
    let t0 = Date()
    while true {
        for e in detector.update(Probes.snapshot(), now: Date().timeIntervalSince(t0)) {
            print("\(Date().formatted(date: .omitted, time: .standard)) \(e)")
        }
        fflush(stdout)
        Thread.sleep(forTimeInterval: 1)
    }
case "record":
    let seconds = Double(args.dropFirst().first ?? "") ?? 10
    let capture = MeetingCapture()
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/shepetal/meetings/\(stamp.string(from: Date()))")
    do {
        try capture.start(dir: dir)
        print("recording \(seconds)s to \(dir.path)/Me.wav and Others.wav")
        Thread.sleep(forTimeInterval: seconds)
        try capture.stop()
        print("saved \(dir.path)/Me.wav and Others.wav")
    } catch {
        print("record failed: \(error)")
        exit(1)
    }
default:
    print("usage: shepetal-meeting probe | watch | record [seconds]")
    exit(2)
}
#else
print("shepetal-meeting needs macOS (Core Audio); MeetingCore is portable.")
#endif
