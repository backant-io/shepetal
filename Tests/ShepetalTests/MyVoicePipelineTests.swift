import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// F38: dictation and History's re-transcribe read voice.json from the pipeline's own data dir each time, so a Save
/// in Settings applies to the next dictation. A temp data dir, a throwaway defaults suite and a private pasteboard:
/// never the user's clipboard, settings or data.
final class MyVoicePipelineTests: XCTestCase {
    var root: URL!
    var pasteboard: NSPasteboard!
    var defaults: UserDefaults!
    var suite = ""

    final class VoiceModel: CleanupModel, @unchecked Sendable {
        let name = "voice"
        var voices: [MyVoice] = []
        func rewrite(_ text: String) throws -> String { text }
        func rewrite(_ text: String, context: CleanupContext, voice: MyVoice) throws -> String {
            voices.append(voice)
            return voice.isEmpty ? text : text.replacingOccurrences(of: "do not", with: "don't")
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-test-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("shepetal-test-\(UUID().uuidString)"))
        suite = "shepetal-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testEachDictationReadsMyVoiceFromTheDataDir() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        pipeline.appFormat = AppFormat(defaults)
        pipeline.styleDefaults = defaults  // no style picked
        let model = VoiceModel()
        pipeline.cleanup = model
        XCTAssertEqual(pipeline.voiceFile, root.appendingPathComponent("voice.json"))
        let plain = await pipeline.finishText("I do not think so.")
        XCTAssertEqual(plain.text, "I do not think so.")
        XCTAssertEqual(model.voices, [], "no voice, no cue: the model is not asked, as before F38")
        let voice = MyVoice(preferences: "Use contractions.")
        try voice.save(pipeline.voiceFile)  // what Settings' Save does
        let voiced = await pipeline.finishText("I do not think so.")
        XCTAssertEqual(voiced.text, "I don't think so.")
        XCTAssertEqual(model.voices, [voice], "the next dictation gets the saved voice")
    }
}
