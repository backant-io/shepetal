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

@Test func wavIsReadableWhileRecording() throws {
    // #100: a crash or Ctrl-C before close must not leave a file whose header says 0 frames.
    let root = scratchDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try MeetingCapture.makeOwnerOnlyDir(root)
    let url = root.appending(path: "x.wav")
    let writer = try WavWriter(url: url, rate: 48000, channels: 1)
    let chunk = [Float](repeating: 0.25, count: 480)
    for _ in 0..<300 { try chunk.withUnsafeBytes { try writer.append($0) } }  // 3 s, never closed below
    let open = try AVAudioFile(forReading: url).length
    #expect(open >= 144_000 - 48_000 && open <= 144_000)  // at most the last second is not in the header yet
    try writer.close()
    let closed = try AVAudioFile(forReading: url)
    #expect(closed.length == 144_000)
    #expect(closed.processingFormat.sampleRate == 48000 && closed.processingFormat.channelCount == 1)
    let pcm = AVAudioPCMBuffer(pcmFormat: closed.processingFormat, frameCapacity: 10)!
    try closed.read(into: pcm, frameCount: 10)
    #expect(pcm.floatChannelData![0][9] == 0.25)  // the samples themselves, not only the size
    #expect(throws: (any Error).self) { try WavWriter(url: url, rate: 48000, channels: 1) }  // never overwrites
}

@Test func meetingFilesHoldTheAudioBeforeStop() throws {
    // The capture's own write path, then no stop(): what a crash mid-meeting leaves behind.
    let dir = scratchDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try MeetingCapture.makeOwnerOnlyDir(dir)
    let capture = MeetingCapture()
    for _ in 0..<200 { feed(capture, buffers: 2, frames: 480, dir: dir) }  // 2 s
    for name in ["Me.wav", "Others.wav"] {
        #expect(try AVAudioFile(forReading: dir.appending(path: name)).length >= 48_000)
    }
}

@Test func captureRecordsAgainAfterAFailure() throws {
    // #100: stop() clears the first meeting's error and files, so the same instance records the next one.
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
