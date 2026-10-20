#if canImport(CoreAudio)
import AVFoundation
import Foundation
import Testing
@testable import MeetingMac

@Test func snapshotCarriesDeviceAndWakeSignals() {
    // The detector's device-change grace and wake holdoff only work if the probe fills these.
    let s = Probes.snapshot()
    #expect(s.devices.count == 2)
    #expect(s.devices.contains { $0 != 0 })
    #expect(s.wakeMarker.hasSuffix("/0"))
    #expect(!s.wakeMarker.hasPrefix("-1."))
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
#endif
