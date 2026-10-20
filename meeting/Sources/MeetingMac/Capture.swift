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
    var me: AVAudioFile?
    var others: AVAudioFile?

    public init() {}

    public func start(dir: URL) throws {
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
            // ponytail: disk I/O on the real-time audio thread; move to a ring buffer + writer
            // thread before shipping. Assumes buffer 0 = mic, last buffer = tap (sub-devices first).
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard buffers.count >= 2 else { return }
            write(buffers[0], rate: rate, to: &me, url: dir.appendingPathComponent("Me.wav"))
            write(buffers[buffers.count - 1], rate: rate, to: &others, url: dir.appendingPathComponent("Others.wav"))
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start")
    }

    public func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        me = nil
        others = nil  // closing the AVAudioFile finalises the WAV header
    }

    func write(_ buffer: AudioBuffer, rate: Double, to file: inout AVAudioFile?, url: URL) {
        let channels = AVAudioChannelCount(max(buffer.mNumberChannels, 1))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: channels, interleaved: true) else { return }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: format.settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: true)
        }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        guard let file, let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &list) else { return }
        try? file.write(from: pcm)
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
