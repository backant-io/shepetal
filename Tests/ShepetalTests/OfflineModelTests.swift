import FluidAudio
import XCTest
@testable import Shepetal

/// #78: FluidAudio treats a model folder it cannot load as corrupt, deletes it and downloads it again, unless
/// its offline mode is on. A truncated file after a full disk would then cost the user 470 MB of download they
/// never asked for, or the whole model when the Mac is offline. The app turns offline mode on at launch, so
/// a broken cache stays on disk and the load just fails.
final class OfflineModelTests: XCTestCase {
    func testBrokenModelCacheIsNeitherDeletedNorDownloaded() async throws {
        ModelRegistry.baseURL = "http://127.0.0.1:9"  // were offline mode off, the re-download fails here, not on the internet
        ParakeetEngine.stayOffline()
        let base = ProcessInfo.processInfo.environment["SHEPETAL_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("offline-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(ParakeetEngine.directory.lastPathComponent)
        // Every file FluidAudio needs is there, so it does not count them missing; none of them loads.
        for name in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            let model = dir.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data("truncated".utf8).write(to: model.appendingPathComponent("model.mil"))
        }
        let broken = dir.appendingPathComponent("Preprocessor.mlmodelc")

        do {
            _ = try await AsrModels.load(from: dir, version: .v3)
            XCTFail("a broken model must not load")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path), "the cache was deleted to download it again")
        XCTAssertTrue(ModelHub.offlineMode)
    }
}
