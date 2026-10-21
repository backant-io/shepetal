#if canImport(CoreAudio)
import Foundation
import MeetingCore
import MeetingMac

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "probe":
    // Only app names, bundle IDs and pids: no window titles or URLs.
    let users = Probes.micUsers()
    if users.isEmpty { print("no process is using the mic") }
    for u in users {
        let app = MeetingDetector.appName(u.path) ?? MeetingDetector.appName(u.responsiblePath) ?? "-"
        print("mic\t\(u.bundleID.isEmpty ? "-" : u.bundleID)\t\(app)\tpid \(u.pid)")
    }
    let snapshot = Probes.snapshot()
    print("camera in use: \(snapshot.cameraInUse ? "yes" : "no")")
    let detector = Probes.detector()
    print("meeting now: \(detector.app(in: snapshot) ?? "none")")
case "watch":
    var detector = Probes.detector()
    let env = ProcessInfo.processInfo.environment
    detector.startAfter = Double(env["START_AFTER"] ?? "") ?? detector.startAfter
    detector.endAfter = Double(env["END_AFTER"] ?? "") ?? detector.endAfter
    print("watching (start after \(detector.startAfter)s, end after \(detector.endAfter)s), ctrl-c to stop")
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
