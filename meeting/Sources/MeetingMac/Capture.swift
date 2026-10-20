#if canImport(CoreAudio)
import AVFoundation
import CoreAudio

/// Records the mic ("Me") and all system audio ("Others") into two WAV files, using a
/// Core Audio process tap inside a private aggregate device (macOS 14.4+). The files stay readable while
/// recording (WavWriter), so a crash keeps everything up to the last second.
/// start() needs mic + "System Audio Recording" permission; tests drive receive() and stop() only.
public final class MeetingCapture {
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var me: WavWriter?
    var others: WavWriter?
    var failure: Error?

    public init() {}

    /// Records into `dir`, created owner-only (0700, files 0600) since it holds meeting audio.
    public func start(dir: URL) throws {
        try Self.makeOwnerOnlyDir(dir)
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create tap")

        guard let micID = read(AudioObjectID(kAudioObjectSystemObject),
                               kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(0)),
              let micUID = readString(micID, kAudioDevicePropertyDeviceUID)
        else { throw CaptureError("no default input device") }

        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "shepetal-meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregateID), "create aggregate")

        let rate = read(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(48000)) ?? 48000
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [self] _, input, _, _, _ in
            receive(input, rate: rate, dir: dir)
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start")
    }

    /// Stops and closes both files. Throws the first capture error, or when nothing was recorded.
    public func stop() throws {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        let wrote = me != nil && others != nil
        var closeError: Error?
        for file in [me, others].compactMap({ $0 }) {
            do { try file.close() } catch { closeError = closeError ?? error }
        }
        let failed = failure ?? closeError
        reset()
        if let failed { throw failed }
        if !wrote { throw CaptureError("no audio was captured") }
    }

    /// Forgets the device, the files and the last error, so the instance can record the next meeting.
    func reset() {
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        me = nil
        others = nil
        failure = nil
    }

    /// One IO cycle of the aggregate device. Keeps the first error for `stop()`.
    func receive(_ input: UnsafePointer<AudioBufferList>, rate: Double, dir: URL) {
        guard failure == nil else { return }
        // ponytail: disk I/O on the real-time audio thread; move to a ring buffer + writer
        // thread before shipping. Assumes buffer 0 = mic, last buffer = tap (sub-devices first).
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        do {
            guard buffers.count >= 2 else { throw CaptureError("expected mic and tap buffers, got \(buffers.count)") }
            try write(buffers[0], rate: rate, to: &me, url: dir.appendingPathComponent("Me.wav"))
            try write(buffers[buffers.count - 1], rate: rate, to: &others, url: dir.appendingPathComponent("Others.wav"))
        } catch {
            failure = error
        }
    }

    /// Appends one interleaved float32 buffer, creating the file (0600) on the first one.
    func write(_ buffer: AudioBuffer, rate: Double, to file: inout WavWriter?, url: URL) throws {
        let channels = Int(max(buffer.mNumberChannels, 1))
        if file == nil { file = try WavWriter(url: url, rate: rate, channels: channels) }
        guard let file, file.channels == channels else {
            throw CaptureError("channel count changed mid-recording in \(url.lastPathComponent)")
        }
        guard let data = buffer.mData else { return }
        try file.append(UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize)))
    }

    /// Creates `dir` and missing parents as 0700, and tightens `dir` if it already exists.
    static func makeOwnerOnlyDir(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
}

struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CaptureError("\(what) failed: OSStatus \(status)") }
}
#endif
