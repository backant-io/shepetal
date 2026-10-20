#if canImport(CoreAudio)
import Foundation

/// A 32-bit float WAV that is valid on disk while it records. The header is written first with zero
/// sizes, and the RIFF and data sizes are patched in place after every second of audio and on `close()`.
/// A crash, force quit or Ctrl-C therefore loses at most the last second, not the whole meeting
/// (AVAudioFile only writes the sizes when the file is closed).
final class WavWriter {
    let channels: Int
    let rate: Int
    private var fd: Int32
    private(set) var frames = 0
    private var patchedFrames = 0

    /// Creates `url` as a new 0600 file. Fails if it exists, so an earlier recording is never overwritten.
    init(url: URL, rate: Double, channels: Int) throws {
        self.channels = channels
        self.rate = Int(rate.rounded())
        fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        fchmod(fd, 0o600)  // the umask can only take bits away, but keep the mode explicit
        try Self.header(rate: self.rate, channels: channels, dataBytes: 0).withUnsafeBytes { try put($0, at: nil) }
    }

    deinit { if fd >= 0 { try? close() } }

    /// Appends interleaved float32 frames.
    func append(_ bytes: UnsafeRawBufferPointer) throws {
        try put(bytes, at: nil)
        frames += bytes.count / (4 * channels)
        if frames - patchedFrames >= rate { try patch() }
    }

    /// Writes the current sizes into the header.
    func patch() throws {
        let data = UInt32(clamping: frames * 4 * channels)
        try withUnsafeBytes(of: (36 + data).littleEndian) { try put($0, at: 4) }
        try withUnsafeBytes(of: data.littleEndian) { try put($0, at: 40) }
        patchedFrames = frames
    }

    func close() throws {
        defer { Darwin.close(fd); fd = -1 }
        try patch()
    }

    private func put(_ bytes: UnsafeRawBufferPointer, at offset: off_t?) throws {
        var done = 0
        while done < bytes.count {
            let base = bytes.baseAddress! + done
            let n = offset.map { pwrite(fd, base, bytes.count - done, $0 + off_t(done)) } ?? write(fd, base, bytes.count - done)
            guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            done += n
        }
    }

    /// The 44-byte header of a WAVE_FORMAT_IEEE_FLOAT file.
    static func header(rate: Int, channels: Int, dataBytes: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(3); u16(UInt16(channels)); u32(UInt32(rate)); u32(UInt32(rate * channels * 4))
        u16(UInt16(channels * 4)); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}
#endif
