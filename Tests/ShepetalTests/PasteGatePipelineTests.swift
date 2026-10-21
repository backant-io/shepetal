import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// Rule 8 through the real Pipeline: the text is pasted only into the window that stayed in focus and only
/// when secure input is off. Otherwise no Cmd+V is posted and the text is left on the clipboard with a ⌘V
/// hint. Runs on a temp data dir and a private pasteboard, never on the user's clipboard or data.
@MainActor
final class PasteGatePipelineTests: XCTestCase {
    private var root: URL!
    private var pasteboard: NSPasteboard!
    private var pastes = 0

    /// 1 s at about -30 dBFS: speech-level audio.
    private let samples = (0..<AudioStore.sampleRate).map { Float(sin(Double($0) * 0.2)) * 0.045 }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-gate-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("io.backant.shepetal.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("earlier", forType: .string)
        pastes = 0
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private func process(_ engine: StubEngine, context: @escaping () -> Void = {}, focusKept: @escaping () -> Bool?,
                         secureInput: @escaping () -> String?) async throws -> (Pipeline.Run, HistoryEntry) {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let run = await pipeline.process(samples, engine: engine, context: { context(); return ("", "", "") },
                                         focusKept: focusKept, secureInput: secureInput, sendPaste: { [unowned self] event in
            // The target app reading the promised item is what makes the paste land.
            if event.type == .keyDown { pastes += 1; _ = pasteboard.string(forType: .string) }
        })
        let row = try XCTUnwrap(try pipeline.history.recent().first { $0.id == run.entry.id })
        return (run, row)
    }

    private func assertOnClipboard(_ run: Pipeline.Run, _ row: HistoryEntry, message: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pastes, 0, "no Cmd+V may be posted", file: file, line: line)
        XCTAssertFalse(run.inserted.isEmpty, file: file, line: line)
        XCTAssertEqual(pasteboard.string(forType: .string), run.inserted, "the text waits on the clipboard", file: file, line: line)
        let types = pasteboard.types ?? []
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
            XCTAssertTrue(types.contains(.init(marker)), "clipboard managers must skip it: \(marker)", file: file, line: line)
        }
        XCTAssertEqual(run.error, message, file: file, line: line)
        XCTAssertEqual(row.outcome, .pasteFailed, file: file, line: line)
        XCTAssertEqual(row.text, run.entry.text, "Recent keeps the text too", file: file, line: line)
    }

    func testSecureInputLeavesTheTextOnTheClipboard() async throws {
        let (run, row) = try await process(StubEngine("hello there"), focusKept: { true }, secureInput: { "Terminal" })
        assertOnClipboard(run, row, message: "Secure input is on in Terminal. The text is on the clipboard: press ⌘V to paste it.")
    }

    // Focus is checked when the text is ready, not when the recording ends: the user clicked away while
    // the model was still running.
    func testFocusMovedWhileTranscribingLeavesTheTextOnTheClipboard() async throws {
        let engine = StubEngine("hello there")
        let (run, row) = try await process(engine, focusKept: { !engine.called }, secureInput: { nil })
        assertOnClipboard(run, row, message: PasteGate.focusMoved)
    }

    // When the window changed, the field that has focus now is not where the text goes, so it is not read.
    func testFocusMovedDecidesWithoutReadingTheNewField() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        var reads = 0
        let run = await pipeline.process(samples, engine: StubEngine("hello there"),
                                         context: { reads += 1; return ("Earlier text", "", "") },
                                         focusKept: { false }, secureInput: { nil },
                                         sendPaste: { [unowned self] _ in pastes += 1 })
        XCTAssertEqual(reads, 0, "the field that took focus must not be read")
        XCTAssertEqual(pastes, 0)
        XCTAssertEqual(run.error, PasteGate.focusMoved)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello there", "the text waits on the clipboard as dictated")
    }

    // Rule 8 holds up to the Cmd+V: reading the field takes AX round trips, and the user can switch windows or
    // reach a password field (secure input) during them.
    func testFocusOrSecureInputChangingWhileTheFieldIsReadBlocksThePaste() async throws {
        for secure in [false, true] {
            var read = false
            let (run, row) = try await process(StubEngine("hello there"), context: { read = true },
                                               focusKept: { secure || !read }, secureInput: { secure && read ? "Safari" : nil })
            assertOnClipboard(run, row, message: secure ? PasteGate.secureInput("Safari") : PasteGate.focusMoved)
            XCTAssertTrue(read)
        }
    }

    // M-NS-1 on Pavel's Mac (build 6298f40): with under 1 GB free and macOS purging space, the WAV write on the
    // main thread took 86 s. The file's last change is at 00:41:56.857 and the main thread logged again right
    // after it, while only Shepetal was reported not responding. Then focus had long moved. The write must hold
    // neither the main thread nor the transcript and the rule-8 decision, and the audio and its row are still kept.
    func testAStalledAudioWriteHoldsNeitherTheMainThreadNorTheDecision() async throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let disk = DispatchSemaphore(value: 0), written = DispatchSemaphore(value: 0), write = pipeline.writeAudio
        pipeline.writeAudio = { samples, id in
            _ = disk.wait(timeout: .now() + 3)  // the disk answers once the decision is made, or after 3 s
            defer { written.signal() }
            return try write(samples, id)
        }
        var writtenAtDecision: Bool?
        let run = await pipeline.process(samples, engine: StubEngine("hello there"), context: { ("", "", "") },
                                         focusKept: { false }, secureInput: { nil },
                                         sendPaste: { [unowned self] _ in pastes += 1 }, decided: {
            XCTAssertEqual($0, PasteGate.focusMoved)
            writtenAtDecision = written.wait(timeout: .now()) == .success
            disk.signal()
        })
        XCTAssertEqual(writtenAtDecision, false, "rule 8 decided on the main thread while the WAV was still being written")
        XCTAssertEqual(pastes, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello there", "the text waits on the clipboard")
        let row = try XCTUnwrap(try pipeline.history.recent().first { $0.id == run.entry.id })
        XCTAssertEqual(row.outcome, .pasteFailed)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: row.audioPath)), AudioStore.wav(samples), "the audio is kept")
        XCTAssertEqual(run.error, PasteGate.focusMoved, "no WAV or history error after the stall")
    }

    // Focus that cannot be read (no Accessibility) does not block the paste; the paste check is the backstop.
    func testUnknownFocusPastesAndRestoresTheClipboard() async throws {
        let (run, row) = try await process(StubEngine("hello there"), focusKept: { nil }, secureInput: { nil })
        XCTAssertEqual(pastes, 1)
        XCTAssertNil(run.error)
        XCTAssertEqual(run.paste?.landed, true)
        XCTAssertEqual(row.outcome, .inserted)
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier", "a landed paste gives the old clipboard back")
    }
}

private final class StubEngine: SpeechEngine {
    let name = "stub"
    let text: String
    private(set) var called = false

    init(_ text: String) { self.text = text }

    func transcribe(_ samples: [Float], wav: URL) async throws -> String {
        called = true
        return text
    }
}
