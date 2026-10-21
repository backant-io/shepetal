import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// #253, "100% private.": every write shepetal makes to a pasteboard is for this Mac only, so Universal Clipboard
/// never offers dictated text to the user's other Apple devices. Each test writes to a private pasteboard that
/// records how every write started. The user's clipboard is never read or written.
@MainActor
final class LocalPasteboardTests: XCTestCase {
    /// A private, uniquely named pasteboard that records the options each write starts with ([] for a plain clear).
    final class Recording: NSPasteboard {
        var starts: [NSPasteboard.ContentsOptions] = []
        override func clearContents() -> Int { starts.append([]); return super.clearContents() }
        override func prepareForNewContents(with options: NSPasteboard.ContentsOptions = []) -> Int {
            starts.append(options)
            return super.prepareForNewContents(with: options)
        }
        override func declareTypes(_ newTypes: [NSPasteboard.PasteboardType], owner newOwner: Any?) -> Int {
            starts.append([])
            return super.declareTypes(newTypes, owner: newOwner)
        }
    }

    private var pasteboard: Recording!
    private var root: URL!

    override func setUp() async throws {
        pasteboard = try XCTUnwrap(Recording.withUniqueName() as? Recording)
        XCTAssertNotEqual(pasteboard.name, .general)
        pasteboard.clearContents()
        pasteboard.setString("earlier", forType: .string)
        pasteboard.starts = []
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-local-pb-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private func assertOnThisMacOnly(_ writes: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pasteboard.starts.map(\.rawValue), Array(repeating: NSPasteboard.ContentsOptions.currentHostOnly.rawValue, count: writes),
                       "\(what): every write must start with prepareForNewContents(with: .currentHostOnly)", file: file, line: line)
    }

    /// The paste path: the dictation goes on the clipboard for ⌘V, then the user's old clipboard comes back. Both
    /// writes stay here; the old one too, since it may have been host-only (a password manager's).
    func testThePasteAndTheRestoreStayOnThisMac() async {
        let pb = pasteboard!
        var pasted: String?
        let r = await Inserter(pasteboard: pb).insert("Hello there.", sendPaste: { event in
            if event.type == .keyDown { pasted = pb.string(forType: .string) }  // the target app takes the paste
        })
        XCTAssertTrue(r.landed)
        XCTAssertEqual(pasted, "Hello there.")
        XCTAssertEqual(pb.string(forType: .string), "earlier", "the old clipboard is back")
        assertOnThisMacOnly(2, "paste, then restore")
    }

    /// Rule 8's fallback: text that cannot be pasted waits on the clipboard for ⌘V.
    func testTextLeftOnTheClipboardStaysOnThisMac() {
        Inserter(pasteboard: pasteboard).leaveOnClipboard("Press ⌘V for me.")
        XCTAssertEqual(pasteboard.string(forType: .string), "Press ⌘V for me.")
        assertOnThisMacOnly(1, "clipboard fallback")
    }

    /// Copy last (⌃⌘C), the 🤫 menu's Recent and the History tab's Copy all go through `Pipeline.copy`.
    func testCopyStaysOnThisMac() throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        pipeline.copy("Copied text.")
        XCTAssertEqual(pasteboard.string(forType: .string), "Copied text.")
        assertOnThisMacOnly(1, "Pipeline.copy")
    }

    /// The meeting Copy buttons and Copy setup for AI apps write the general pasteboard, which no test may touch,
    /// so these pin every write in the app's source instead: a write can only start with a clear, and the only clear
    /// is `clearOnThisMac()`. A new `clearContents()` (a Copy button, snippets, a share card) fails here.
    func testEveryWriteInTheAppStartsOnThisMacOnly() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources")
            .standardizedFileURL
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "found the sources")
        var prepares: [String] = []
        for f in files {
            let code = try String(contentsOf: f, encoding: .utf8).components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for l in code {
                for banned in ["clearContents", "declareTypes"] {  // bare words: `clearContents ()` and #selector too
                    XCTAssertFalse(l.contains(banned), "\(f.lastPathComponent): \(l.trimmingCharacters(in: .whitespaces)) – use clearOnThisMac()")
                }
                if l.contains("prepareForNewContents") { prepares.append(l.trimmingCharacters(in: .whitespaces)) }
            }
        }
        XCTAssertEqual(prepares, ["func clearOnThisMac() { _ = prepareForNewContents(with: .currentHostOnly) }"])
        for (file, line) in [("Meetings/MeetingsView.swift", "NSPasteboard.general.clearOnThisMac()"),
                             ("MCP.swift", "NSPasteboard.general.clearOnThisMac()"),
                             ("Pipeline.swift", "inserter.pasteboard.clearOnThisMac()")] {
            XCTAssertTrue(try AppSource.code(file).contains(line), "\(file) lacks \(line)")
        }
    }
}
