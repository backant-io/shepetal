#if canImport(CoreAudio)
import AVFoundation
import CoreMediaIO
import Foundation
import MeetingCore
import Testing
@testable import MeetingMac

@Test func snapshotCarriesDeviceAndWakeSignals() {
    // The detector's device-change grace and wake holdoff only work if the probe fills these. Only these two are
    // read: the mic users and the camera state of the machine running the tests are left alone.
    let devices = Probes.devices()
    #expect(devices.count == 2)
    #expect(devices.contains { $0 != 0 })
    let wake = Probes.wakeMarker()
    #expect(wake.hasSuffix("/0"))
    #expect(!wake.hasPrefix("-1."))
}

@Test func theCLIIgnoresTheShepetalAppsDictation() {
    // MEET-4: `shepetal-meeting watch` runs in its own process, so excluding only its pid would make the Shepetal
    // app's dictation (another pid) a meeting. The app is skipped by its exact bundle ID; other apps still count.
    var d = Probes.detector()
    let app = MicUser(pid: getpid() + 1, bundleID: "io.backant.shepetal", path: "/Applications/Shepetal.app/Contents/MacOS/Shepetal")
    for t in 0...20 { #expect(d.update(Snapshot(micUsers: [app]), now: Double(t)).isEmpty) }
    let zoom = MicUser(pid: getpid() + 2, bundleID: "us.zoom.xos", path: "/Applications/zoom.us.app/Contents/MacOS/zoom.us")
    #expect(d.app(in: Snapshot(micUsers: [app, zoom])) == "zoom.us")
    #expect(d.app(in: Snapshot(micUsers: [MicUser(pid: getpid(), path: "/usr/local/bin/shepetal-meeting")])) == nil)
}

/// A fake property graph keyed by [object, selector]: what Core Audio or CoreMediaIO would answer, and nothing else.
func fixture(ids: [[UInt32]: [UInt32]], numbers: [[UInt32]: UInt32] = [:], strings: [[UInt32]: String] = [:]) -> PropertyReader {
    PropertyReader(ids: { ids[[$0, $1]] ?? [] }, number: { numbers[[$0, $1]] }, string: { strings[[$0, $1]] })
}

@Test func theMicProbeListsOnlyProcessesCapturingInputWithTheirPidAndBundleID() {
    // #62: micUsers() is the main meeting trigger. This fixture is the process list Core Audio gives during a Zoom
    // call with music playing and the Shepetal app dictating. Pids are above macOS's PID_MAX (99999), so the path
    // lookup finds no real process.
    let system = AudioObjectID(kAudioObjectSystemObject)
    let (zoom, music, shepetal, unreadable): (UInt32, UInt32, UInt32, UInt32) = (0x70, 0x71, 0x72, 0x73)
    var numbers: [[UInt32]: UInt32] = [:]
    for (id, pid, input, output) in [(zoom, 100_070, 1, 1), (music, 100_071, 0, 1), (shepetal, 100_072, 1, 0)] {
        numbers[[id, kAudioProcessPropertyPID]] = UInt32(pid)
        numbers[[id, kAudioProcessPropertyIsRunningInput]] = UInt32(input)
        numbers[[id, kAudioProcessPropertyIsRunningOutput]] = UInt32(output)
    }
    let r = fixture(ids: [[system, kAudioHardwarePropertyProcessObjectList]: [zoom, music, shepetal, unreadable]],
                    numbers: numbers,
                    strings: [[zoom, kAudioProcessPropertyBundleID]: "us.zoom.xos",
                              [music, kAudioProcessPropertyBundleID]: "com.apple.Music",
                              [shepetal, kAudioProcessPropertyBundleID]: "io.backant.shepetal"])
    let users = Probes.micUsers(r)
    // Music only plays (output), and a process whose state cannot be read is not a mic user.
    #expect(users.map(\.pid) == [100_070, 100_072])
    #expect(users.map(\.bundleID) == ["us.zoom.xos", "io.backant.shepetal"])
    // The bundle ID is how the CLI skips the Shepetal app's own dictation: without Zoom nothing is a meeting.
    #expect(Probes.detector().app(in: Snapshot(micUsers: users.filter { $0.pid != 100_070 })) == nil)
    #expect(Probes.detector().app(in: Snapshot(micUsers: users)) != nil)
}

@Test func theCameraProbeSeesARunningCameraAmongIdleOnes() {
    // #62: a camera alone is a meeting (Pavel's rule), from CMIO IsRunningSomewhere on any device, not only the first.
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    let devices = [system, CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)]
    let running = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
    let (facetime, external, unreadable): (UInt32, UInt32, UInt32) = (0x30, 0x31, 0x32)
    #expect(Probes.cameraInUse(fixture(ids: [devices: [facetime, unreadable, external]],
                                       numbers: [[facetime, running]: 0, [external, running]: 1])))
    #expect(!Probes.cameraInUse(fixture(ids: [devices: [facetime, unreadable, external]],
                                        numbers: [[facetime, running]: 0, [external, running]: 0])))
    #expect(!Probes.cameraInUse(fixture(ids: [devices: []])))
}

/// Two mono buffers (mic, tap) as the aggregate device delivers them.
func feed(_ capture: MeetingCapture, buffers: Int, frames: Int, dir: URL) {
    var samples = [Float](repeating: 0.25, count: frames)
    let list = AudioBufferList.allocate(maximumBuffers: buffers)
    defer { free(list.unsafeMutablePointer) }
    samples.withUnsafeMutableBytes { raw in
        for i in 0..<buffers {
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
        }
        capture.receive(list.unsafePointer, rate: 48000, dir: dir)
    }
}

func scratchDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "shepetal-meeting-tests-\(UUID().uuidString)")
}

func mode(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Test func meetingAudioIsOwnerOnly() throws {
    // Goal rule 4: meeting audio of the user and the others lives in a 0700 dir as 0600 files,
    // even when the process umask would make them world-readable.
    let old = umask(0o022)
    defer { umask(old) }
    let root = scratchDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appending(path: "meetings/one")
    try MeetingCapture.makeOwnerOnlyDir(dir)
    let capture = MeetingCapture()
    feed(capture, buffers: 2, frames: 480, dir: dir)
    feed(capture, buffers: 2, frames: 480, dir: dir)
    try capture.stop()
    #expect(try mode(root) == 0o700)
    #expect(try mode(dir) == 0o700)
    for name in ["Me.wav", "Others.wav"] {
        let url = dir.appending(path: name)
        #expect(try mode(url) == 0o600)
        #expect(try AVAudioFile(forReading: url).length == 960)
    }
    // A dir that already exists with looser bits is tightened.
    let loose = root.appending(path: "loose")
    try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o755])
    try MeetingCapture.makeOwnerOnlyDir(loose)
    #expect(try mode(loose) == 0o700)
}

@Test func captureFailuresAreReported() throws {
    // `record` must not print success and exit 0 when nothing was written.
    #expect(throws: CaptureError.self) { try MeetingCapture().stop() }  // no audio arrived

    // The real cause reaches the user, not just "no audio".
    let oneBuffer = MeetingCapture()
    feed(oneBuffer, buffers: 1, frames: 480, dir: scratchDir())
    let layout = #expect(throws: CaptureError.self) { try oneBuffer.stop() }
    #expect(layout?.description.contains("expected mic and tap buffers") == true)

    let missingDir = MeetingCapture()
    feed(missingDir, buffers: 2, frames: 480, dir: URL(fileURLWithPath: "/nonexistent-shepetal-dir"))
    let write = #expect(throws: (any Error).self) { try missingDir.stop() }
    #expect(write != nil && !(write is CaptureError))  // the file system error itself
}

@Test func aKilledRecordingLeavesPlayableFilesWithEveryFrame() throws {
    // #100: a crash, a force quit or a kill mid-meeting must not leave WAVs that read as empty. stop() is never
    // called and the capture stays open, as when the process dies: the writes are unbuffered, so this is what a
    // killed process leaves on disk. Both files must already parse, with every frame written so far.
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try MeetingCapture.makeOwnerOnlyDir(dir)
    let capture = MeetingCapture()
    for _ in 0..<150 { feed(capture, buffers: 2, frames: 480, dir: dir) }  // 1.5 s at 48 kHz
    for name in ["Me.wav", "Others.wav"] {
        let file = try AVAudioFile(forReading: dir.appending(path: name))
        #expect(file.length == 72_000)
        #expect(file.fileFormat.sampleRate == 48_000)
        file.framePosition = 71_999  // the last frame written holds the fed sample
        let last = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
        try file.read(into: last)
        #expect(last.frameLength == 1 && last.floatChannelData?[0][0] == 0.25)
    }
    withExtendedLifetime(capture) {}
}

@Test func micBuffersAreInterleavedFrameByFrame() throws {
    // AVAudioEngine hands the mic over one buffer per channel; the WAV must hold L R L R, or a stereo mic's
    // channels come back swapped or scrambled.
    let url = scratchDir().appendingPathExtension("wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
    buffer.frameLength = 3
    for f in 0..<3 { buffer.floatChannelData![0][f] = Float(f); buffer.floatChannelData![1][f] = Float(-f - 1) }
    let writer = try WavWriter(url, rate: 16_000, channels: 2)
    try writer.append(buffer)
    #expect(try mode(url) == 0o600)
    let samples = try Data(contentsOf: url).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(samples == [0, -1, 1, -2, 2, -3])
    #expect(try AVAudioFile(forReading: url).length == 3)
}

@Test func aCaptureRecordsAgainAfterAFailedMeeting() throws {
    // #100: one failed meeting must not make the next start() on the same capture record nothing.
    let capture = MeetingCapture()
    feed(capture, buffers: 1, frames: 480, dir: scratchDir())
    #expect(throws: CaptureError.self) { try capture.stop() }
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try MeetingCapture.makeOwnerOnlyDir(dir)
    feed(capture, buffers: 2, frames: 480, dir: dir)
    try capture.stop()
    #expect(try AVAudioFile(forReading: dir.appending(path: "Me.wav")).length == 480)
}
#endif
