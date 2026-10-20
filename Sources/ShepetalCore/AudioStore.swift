import Foundation

public enum Retention: String, CaseIterable {
    case keep              // default
    case delete24h = "delete_after_24h"
}

/// Keeps the raw audio of every recording: the exact 16 kHz mono Float32 samples the model got,
/// as WAV files in an owner-only directory (0700 dir, 0600 files).
public struct AudioStore {
    public static let sampleRate = 16_000
    public let dir: URL

    public init(dir: URL) throws {
        try Self.makeOwnerOnlyDirectory(dir)
        self.dir = dir
    }

    /// Creates `url` (and parents) as 0700, and tightens it if it already exists.
    public static func makeOwnerOnlyDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    @discardableResult
    public func save(_ samples: [Float], id: String) throws -> URL {
        let url = dir.appendingPathComponent("\(id).wav")
        guard FileManager.default.createFile(atPath: url.path, contents: Self.wav(samples),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
    }

    /// Deletes recordings older than 24 h when retention asks for it. Returns what was deleted.
    @discardableResult
    public func applyRetention(_ retention: Retention, now: Date = Date()) throws -> [URL] {
        guard retention == .delete24h else { return [] }
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-24 * 3600)
        var deleted: [URL] = []
        for url in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        where url.pathExtension == "wav" {
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? now
            if modified <= cutoff {
                try fm.removeItem(at: url)
                deleted.append(url)
            }
        }
        return deleted
    }

    /// 32-bit float, mono, 16 kHz WAV, so the file holds the samples bit for bit.
    public static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(3); u16(1)                                   // IEEE float, mono
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
