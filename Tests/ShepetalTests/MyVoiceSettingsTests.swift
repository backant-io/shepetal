import ShepetalCore
import XCTest
@testable import Shepetal

/// F38: Settings' My voice writes voice.json, which dictation reads, and gets the cleanup model ready for it.
@MainActor
final class MyVoiceSettingsTests: XCTestCase {
    /// Records the voice of each call.
    final class Recorder: CleanupModel, @unchecked Sendable {
        let name = "recorder"
        var voices: [MyVoice] = []
        func rewrite(_ text: String) throws -> String { text }
        func rewrite(_ text: String, context: CleanupContext, voice: MyVoice) throws -> String {
            voices.append(voice)
            return text
        }
    }

    private func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("myvoice-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("voice.json")
    }

    // What the user types is what the next dictation reads, owner-only, and the model decodes its prompt for it
    // at Save, not in the middle of the next dictation.
    func testSaveWritesTheFileAndWarmsTheModel() async throws {
        let url = try tempFile(), recorder = Recorder()
        let model = MyVoiceModel(url: url, cleanup: { recorder })
        XCTAssertEqual(model.samples, ["", "", ""], "three empty samples to fill")
        model.preferences = "Never use exclamation marks."
        model.samples[1] = "Can't wait, see you there."
        XCTAssertNotEqual(model.draft, model.saved, "Save has something to save")
        model.save()
        await model.warming?.value
        let voice = MyVoice(preferences: "Never use exclamation marks.", samples: ["Can't wait, see you there."])
        XCTAssertEqual(MyVoice.load(url), voice)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(recorder.voices, [voice])
        XCTAssertEqual(model.draft, model.saved)
        XCTAssertEqual(model.samples, ["Can't wait, see you there.", "", ""], "the saved voice, as dictation reads it")
        XCTAssertEqual(MyVoiceModel(url: url, cleanup: { nil }).preferences, voice.preferences, "the Hub opens with it")
    }

    // Clearing everything turns My voice off: no file, so dictation is as before F38.
    func testClearingEverythingTurnsItOff() throws {
        let url = try tempFile()
        try MyVoice(preferences: "Lowercase.").save(url)
        let model = MyVoiceModel(url: url, cleanup: { nil })
        model.preferences = ""
        model.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(model.warming, "no model, nothing to warm")
    }

    func testAFailedSaveSaysSo() throws {
        let url = try tempFile().deletingLastPathComponent().appendingPathComponent("missing/voice.json")
        let model = MyVoiceModel(url: url, cleanup: { nil })
        model.preferences = "Lowercase."
        model.save()
        XCTAssertTrue(model.message.hasPrefix("My voice: "), model.message)
    }
}
