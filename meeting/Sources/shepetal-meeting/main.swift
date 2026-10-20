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
    print("meeting apps now: \(detector.meetingApps(in: Probes.snapshot()).sorted())")
case "watch":
    var detector = MeetingDetector(
        startAfter: Double(ProcessInfo.processInfo.environment["START_AFTER"] ?? "") ?? 5,
        endAfter: Double(ProcessInfo.processInfo.environment["END_AFTER"] ?? "") ?? 10)
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
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    do {
        try capture.start(dir: dir)
        print("recording \(seconds)s to \(dir.path)/Me.wav and Others.wav")
        Thread.sleep(forTimeInterval: seconds)
        capture.stop()
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
