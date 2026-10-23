import AppKit
import Vision
import XCTest
import ShepetalCore
import SwiftUI
@testable import Shepetal

/// The Dictionary screen and the Settings input rows in the shepetal UI, drawn offscreen at 2x in Concrete and
/// Night for review (.github/workflows/screens.yml). Fictional words only. Skipped unless SHEPETAL_SCREENSHOTS
/// names an output dir; nothing here reads the account, and no window is ordered front or made key.
@MainActor
final class DictionaryScreenshotTests: XCTestCase {
    private var out: URL!
    private var root: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHEPETAL_SCREENSHOTS"] else {
            throw XCTSkip("SHEPETAL_SCREENSHOTS is not set")
        }
        _ = NSApplication.shared  // a window needs the app object, even in the test bundle
        SHFonts.register()
        out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        NSApp?.appearance = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: shots

    /// Words, starred names and replacements, with the add fields empty (their placeholders show).
    func testDictionaryScreen() throws {
        let model = try model(Self.dictionary)
        try shoot("dictionary-screen", NSSize(width: 760, height: 680),
                  expect: ["Dictionary", "Saoirse", "stand-up", "Edit as text"]) { DictionaryTab(model: model) }
    }

    /// Nothing added yet.
    func testDictionaryEmpty() throws {
        let model = try model([])
        try shoot("dictionary-empty", NSSize(width: 760, height: 420), expect: ["Dictionary", "No words yet"]) {
            DictionaryTab(model: model)
        }
    }

    /// A refused add: the message replaces the help under the list.
    func testDictionaryRefusedAdd() throws {
        let model = try model(["Saoirse", "Okonkwo"])
        XCTAssertFalse(model.add("# note"))
        try shoot("dictionary-refused", NSSize(width: 760, height: 420), expect: ["Type one word or phrase"]) {
            DictionaryTab(model: model)
        }
    }

    /// Settings' Microphone, Languages and Shortcuts rows.
    func testInputSettings() throws {
        try shoot("dictionary-input-settings", NSSize(width: 760, height: 260),
                  expect: ["Microphone", "Languages", "Shortcuts"]) {
            VStack(alignment: .leading) { SHRows { HubInputSettings(input: .none) } }.padding(SH.space5)
        }
    }

    func testFictionalTextIsOnBrand() {
        for l in Self.dictionary {
            XCTAssertFalse(l.unicodeScalars.contains { $0.properties.isEmojiPresentation }, "emoji in “\(l)”")
            assertOnBrand(l, "“\(l)”")
        }
    }

    // MARK: data (fictional: no real people, companies or products)

    private static let dictionary = [
        "*Maya Lindqvist", "*Tomasz Wierzbicki", "Saoirse", "Niamh", "Okonkwo", "Alder Street",
        "stand up => stand-up", "check in => check-in", "my email => maya@example.com",  // example.com is reserved
        "Q four => Q4", "e g => e.g.",
    ]

    private func model(_ lines: [String]) throws -> DictionaryModel {
        let url = root.appendingPathComponent("dictionary.txt")
        try (Vocabulary.header + lines.map { $0 + "\n" }.joined()).write(to: url, atomically: true, encoding: .utf8)
        let model = DictionaryModel(url: url, editAsText: {})
        model.reload()  // the tab's onAppear may not run offscreen
        return model
    }

    // MARK: rendering (as ScreenshotTests)

    /// Concrete, then Night: the view on sh-bg in a window of that appearance, drawn, written and read back.
    private func shoot<V: View>(_ name: String, _ size: NSSize, expect: [String], _ make: () -> V) throws {
        for (mode, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: appearance)
            window.contentView = NSHostingView(rootView: make()
                .padding(.top, 28)  // under the title bar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(SH.bg)
                .environment(\.colorScheme, scheme))
            let image = try render(window, size)
            try write(image, "\(name)-\(mode)@2x.png")
            let seen = try Self.text(in: image)
            for line in expect { XCTAssertTrue(seen.contains(line), "\(name) \(mode) does not show “\(line)”:\n\(seen)") }
            assertOnBrand(seen, "\(name) \(mode)")
            window.close()
        }
    }

    private func render(_ window: NSWindow, _ size: NSSize) throws -> CGImage {
        window.setContentSize(size)
        for _ in 0..<3 {  // SwiftUI lays out and fills its lists on the next passes
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        XCTAssertFalse(window.isVisible, "a screenshot must not put the window on screen")
        let frame = try XCTUnwrap(window.contentView?.superview, "the window has no theme frame")
        let b = frame.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width) * 2, pixelsHigh: Int(b.height) * 2,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = b.size
        frame.cacheDisplay(in: b, to: rep)
        return try XCTUnwrap(rep.cgImage)
    }

    private func write(_ image: CGImage, _ file: String) throws {
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent(file))
    }

    private static func text(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// The name in lowercase, no "AI", no em dash, no other product.
    private func assertOnBrand(_ text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        if let r = text.range(of: #"\bAI\b|Shepetal|Wispr|Superwhisper|MacWhisper|Otter|Granola|Fireflies|Dragon|—|\b(?:Mail|Messages|Zoom|Teams|Slack)\b"#,
                              options: .regularExpression) {
            XCTFail("\(name) shows “\(text[r])”", file: file, line: line)
        }
    }
}
