import XCTest
@testable import ShepetalCore

final class StorageTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-test-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    // Raw audio is the user's own voice: only the owner may read it.
    func testAudioIsOwnerOnly() throws {
        let store = try AudioStore(dir: root.appendingPathComponent("audio"))
        let url = try store.save([0, 0.5, -0.5], id: "a")
        XCTAssertEqual(try mode(store.dir), 0o700)
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testExistingLooseDirectoryIsTightened() throws {
        let dir = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try AudioStore(dir: dir)
        XCTAssertEqual(try mode(dir), 0o700)
    }

    // The file holds the exact samples the model got, at 16 kHz mono, so history can replay and re-transcribe.
    func testWavHoldsExactSamples() throws {
        let samples: [Float] = (0..<1600).map { sin(Float($0) * 0.01) * 0.3 }
        let store = try AudioStore(dir: root)
        let data = try Data(contentsOf: store.save(samples, id: "b"))
        func u16(_ o: Int) -> UInt16 { data.subdata(in: o..<o+2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        func u32(_ o: Int) -> UInt32 { data.subdata(in: o..<o+4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(u16(20), 3, "IEEE float")
        XCTAssertEqual(u16(22), 1, "mono")
        XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(u32(40), UInt32(samples.count * 4))
        let back = data.subdata(in: 44..<data.count).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(back, samples)
    }

    func testRetentionKeepDeletesNothing() throws {
        let store = try AudioStore(dir: root)
        let url = try store.save([0], id: "old")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 24 * 3600)], ofItemAtPath: url.path)
        XCTAssertEqual(try store.applyRetention(.keep), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRetention24hDeletesOnTime() throws {
        let store = try AudioStore(dir: root)
        let now = Date()
        let old = try store.save([0], id: "old")
        let fresh = try store.save([0], id: "fresh")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-24 * 3600 - 1)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-23 * 3600)], ofItemAtPath: fresh.path)
        let deleted = try store.applyRetention(.delete24h, now: now)
        XCTAssertEqual(deleted.map(\.lastPathComponent), ["old.wav"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    // Too-short and cancelled recordings are kept and flagged, each pointing at its owner-only audio file.
    func testHistoryKeepsFlaggedRecordings() throws {
        try AudioStore.makeOwnerOnlyDirectory(root)
        let store = try AudioStore(dir: root.appendingPathComponent("audio"))
        let dbURL = root.appendingPathComponent("history.sqlite")
        let history = try History(path: dbURL)
        XCTAssertEqual(try mode(dbURL), 0o600)

        let t = Date(timeIntervalSince1970: 1_000)
        for (i, outcome) in [Outcome.tooShort, .cancelled, .inserted].enumerated() {
            let audio = try store.save([Float(i)], id: "r\(i)")
            try history.add(HistoryEntry(id: "r\(i)", createdAt: t.addingTimeInterval(Double(i)), outcome: outcome,
                                         audioPath: audio.path, durationMs: 200, model: "m",
                                         rawText: outcome == .inserted ? "um hi" : "", text: outcome == .inserted ? "Hi" : ""))
        }
        let rows = try history.recent()
        XCTAssertEqual(rows.map(\.outcome), [.inserted, .cancelled, .tooShort])
        XCTAssertEqual(rows[0].text, "Hi")
        for row in rows {
            XCTAssertTrue(FileManager.default.fileExists(atPath: row.audioPath))
            XCTAssertEqual(try mode(URL(fileURLWithPath: row.audioPath)), 0o600)
        }
    }
}
