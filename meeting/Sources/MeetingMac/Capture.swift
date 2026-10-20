#if canImport(CoreAudio)
import AVFoundation
import CoreAudio

/// Records the mic ("Me") and all system audio ("Others") into two WAV files, using a
/// Core Audio process tap inside a private aggregate device (macOS 14.2+).
/// Needs mic + "System Audio Recording" permission; never called from tests.
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
        let wrote = me != nil && others != nil, failed = failure
        // All reset, so the next start() on this instance records afresh instead of keeping this failure (#100).
        (procID, me, others, failure) = (nil, nil, nil, nil)
        (aggregateID, tapID) = (AudioObjectID(kAudioObjectUnknown), AudioObjectID(kAudioObjectUnknown))
        if let failed { throw failed }
        if !wrote { throw CaptureError("no audio was captured") }
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

    func write(_ buffer: AudioBuffer, rate: Double, to file: inout WavWriter?, url: URL) throws {
        let channels = Int(max(buffer.mNumberChannels, 1))
        if file == nil { file = try WavWriter(url, rate: rate, channels: channels) }
        guard let file, file.channels == channels, let data = buffer.mData
        else { throw CaptureError("unexpected audio buffer: \(channels) channels") }
        try file.append(UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize)))
    }

    /// Creates `dir` and missing parents as 0700, and tightens `dir` if it already exists.
    static func makeOwnerOnlyDir(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
}

/// An interleaved float32 WAV whose header counts every frame as soon as it is written, so a crash, a force quit
/// or a kill mid-meeting leaves a file that plays up to its last write (#100); AVAudioFile writes the sizes only
/// when it closes. Writes go straight to the file descriptor, unbuffered, so what `append` wrote is on disk.
public final class WavWriter {
    public let channels: Int
    private let handle: FileHandle
    private var bytes: UInt64 = 0

    /// Creates `url` as 0600 (meeting audio, rule 4) with a header that says 0 frames.
    public init(_ url: URL, rate: Double, channels: Int) throws {
        guard rate >= 1, rate <= 768_000, (1...64).contains(channels) else {
            throw CaptureError("unsupported format: \(channels) channels at \(rate) Hz")
        }
        var h = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); u32(36)
        h.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(3); u16(UInt16(channels))  // IEEE float
        u32(UInt32(rate)); u32(UInt32(rate) * UInt32(channels) * 4); u16(UInt16(channels * 4)); u16(32)
        h.append(contentsOf: Array("data".utf8)); u32(0)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0, fchmod(fd, 0o600) == 0 else {
            let e = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            if fd >= 0 { close(fd) }
            throw e
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.channels = channels
        try handle.write(contentsOf: h)
    }

    /// Appends interleaved float32 frames, then rewrites the RIFF and data sizes to count them.
    public func append(_ samples: UnsafeRawBufferPointer) throws {
        try handle.write(contentsOf: samples)
        bytes += UInt64(samples.count)
        // ponytail: the sizes stop at 4 GB (about 3 h of 48 kHz stereo); 0xFFFFFFFF then means "to the end of the
        // file", as the app's WavTail reads it. Write RF64 if such meetings must play in other apps too.
        try patch(at: 4, UInt32(min(36 + bytes, 0xFFFF_FFFF)))
        try patch(at: 40, UInt32(min(bytes, 0xFFFF_FFFF)))
    }

    /// A buffer as AVAudioEngine delivers it, interleaved here when it comes one channel per buffer.
    public func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let ch = buffer.floatChannelData, Int(buffer.format.channelCount) == channels
        else { throw CaptureError("expected \(channels) float32 channels, got \(buffer.format)") }
        let frames = Int(buffer.frameLength)
        if buffer.format.isInterleaved || channels == 1 {
            return try append(UnsafeRawBufferPointer(start: ch[0], count: frames * channels * 4))
        }
        var out = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames { for c in 0..<channels { out[f * channels + c] = ch[c][f] } }
        try out.withUnsafeBytes { try append($0) }
    }

    private func patch(at offset: off_t, _ value: UInt32) throws {
        var v = value.littleEndian
        guard pwrite(handle.fileDescriptor, &v, 4, offset) == 4 else { throw CaptureError("WAV header write failed: errno \(errno)") }
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
