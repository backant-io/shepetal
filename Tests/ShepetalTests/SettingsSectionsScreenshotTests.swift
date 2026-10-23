import AppKit
import SwiftUI
import Vision
import XCTest
import ShepetalCore
@testable import Shepetal

/// Review pictures of the sections restyled to the shepetal UI rows (Settings' Styles, My voice, Email, Formatting
/// per app and Export, and Home's Account, Your stats and Insights), drawn offscreen at 2x with fictional data in
/// Concrete (light) and Night (dark), for .github/workflows/screens.yml. Skipped unless SHEPETAL_SCREENSHOTS names
/// an output dir. The sections are drawn on their own, in a 720 pt content column on sh-bg, as the Hub's tabs place
/// them; the account is a signed-out one with no Keychain, and nothing is written to the defaults. The rendering
/// helpers are copied from ScreenshotTests.
@MainActor
final class SettingsSectionsScreenshotTests: XCTestCase {
    private var out: URL!
    private var root: URL!

    /// Locale.current is read once and then kept, so it is set before anything formats a number.
    nonisolated override class func setUp() {
        super.setUp()
        if ProcessInfo.processInfo.environment["SHEPETAL_SCREENSHOTS"] != nil {
            let d = UserDefaults.standard
            d.setVolatileDomain(d.volatileDomain(forName: UserDefaults.argumentDomain)
                                    .merging(["AppleLocale": "en_US", "AppleLanguages": ["en-US"]]) { $1 },
                                forName: UserDefaults.argumentDomain)
            if let reset = dlsym(dlopen(nil, RTLD_NOW), "_CFLocaleResetCurrent") {
                unsafeBitCast(reset, to: (@convention(c) () -> Void).self)()
            }
        }
    }

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHEPETAL_SCREENSHOTS"] else {
            throw XCTSkip("SHEPETAL_SCREENSHOTS is not set")
        }
        _ = NSApplication.shared
        SHFonts.register()
        out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        NSApp?.appearance = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: shots

    /// Home's Account (signed out: Sign in is the one primary keycap), Your stats and Insights.
    func testHomeSections() throws {
        let history = try filledHistory()
        let account = Account(client: AccountClient(), tokens: TokenStore(read: { nil }, write: { _ in }, delete: {}),
                              stateURL: root.appendingPathComponent("account.json"), required: false)
        try shoot("settings-b-home", NSSize(width: 720, height: 1060), expect: ["Account", "Your stats", "Last 7 days", "Insights"]) {
            VStack(alignment: .leading, spacing: SH.space6) {
                AccountSection(account: account)
                StatsSection(history: history)
                InsightsSection(history: history)
            }
        }
    }

    /// Settings' Styles and My voice: a segmented style per kind of app with its example, and the voice fields.
    func testStylesAndVoice() throws {
        let voice = root.appendingPathComponent("voice.json")
        try MyVoice(preferences: "Short sentences, contractions, no exclamation marks.",
                    samples: ["Thanks for the notes, I'll fold them into the draft tonight."]).save(voice)
        try shoot("settings-b-styles-voice", NSSize(width: 720, height: 1100), expect: ["Styles", "Very casual", "My voice", "Sample 1"]) {
            VStack(alignment: .leading, spacing: SH.space6) {
                StylesSection()
                MyVoiceSection(url: voice, cleanup: { nil })
            }
        }
    }

    /// Settings' Email signature, Formatting per app (one row per app in History) and the Export row.
    func testEmailFormatAndExport() throws {
        let history = try filledHistory()
        try shoot("settings-b-email-format", NSSize(width: 720, height: 900), expect: ["Signature", "All apps", "Per app", "Export"]) {
            VStack(alignment: .leading, spacing: SH.space6) {
                EmailSection()
                AppFormatSection(history: history)
                SHRowGroup("Data") { DataExportButton(history: history, meetings: InMemoryMeetingStore()) }
            }
        }
    }

    // MARK: data (fictional: no real people, companies or products)

    private static let lines: [(app: String, bundleId: String, text: String)] = [
        ("Chat", "com.example.chat", "Running ten minutes late, save me a seat by the window."),
        ("Editor", "com.example.editor", "Three things for today: finish the budget draft, reply to Priya about the venue, and book the train."),
        ("Email", "com.example.email", "Hi Dana, thanks for the new floor plan. We'll go with the second option."),
        ("Chat", "com.example.chat", "Can you grab oat milk on the way home? We're out."),
        ("Editor", "com.example.editor", "Garden schedule: watering on the first two weekends, closed for the winter from the 30th."),
    ]

    /// Dictations today and on most of the last weeks, so the streak, the heatmap and the stats all show values.
    private func filledHistory() throws -> History {
        let history = try History(path: root.appendingPathComponent("history-\(UUID().uuidString).db"))
        let now = Date()
        for day in 0..<120 where day < 9 || day % 3 != 0 {
            for n in 0..<(1 + day % 4) {
                let l = Self.lines[(day + n) % Self.lines.count]
                try history.add(HistoryEntry(id: UUID().uuidString, createdAt: now.addingTimeInterval(-Double(day) * 86_400 - Double(n) * 3_600),
                                             outcome: .inserted, audioPath: "", durationMs: l.text.split(separator: " ").count * 380,
                                             rawText: l.text, text: l.text, app: l.app, bundleId: l.bundleId))
            }
        }
        return history
    }

    // MARK: rendering (as ScreenshotTests)

    /// Light, then Dark: the sections in a window of that appearance, drawn, written and read back.
    private func shoot<Content: View>(_ name: String, _ size: NSSize, expect: [String],
                                      @ViewBuilder _ content: () -> Content) throws {
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.title = "Settings"
            window.contentView = NSHostingView(rootView: content()
                .padding(SH.space5)
                .padding(.top, 28)  // under the title bar
                .frame(width: size.width, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(SH.bg)
                .environment(\.colorScheme, mode == "dark" ? .dark : .light))
            let image = try render(window, size)
            let framed = try Self.framed(image)
            try write(image, "\(name)-\(mode)-window@2x.png")
            try write(framed, "\(name)-\(mode)@2x.png")
            try write(try Self.halved(framed), "\(name)-\(mode).png")
            let seen = try Self.text(in: image)
            for line in expect { XCTAssertTrue(seen.contains(line), "\(name) \(mode) does not show “\(line)”:\n\(seen)") }
            assertOnBrand(seen, "\(name) \(mode)")
            window.close()
        }
    }

    private func render(_ window: NSWindow, _ size: NSSize) throws -> CGImage {
        window.setContentSize(size)
        for _ in 0..<3 {
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
        var background = CGColor(gray: 1, alpha: 1)
        window.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
        let ctx = try Self.context(rep.pixelsWide, rep.pixelsHigh)
        let all = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        ctx.addPath(CGPath(roundedRect: all, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.clip()
        ctx.setFillColor(background)
        ctx.fill(all)
        ctx.draw(try XCTUnwrap(rep.cgImage), in: all)
        return try XCTUnwrap(ctx.makeImage())
    }

    private static func framed(_ window: CGImage) throws -> CGImage {
        let w = 2540.0, h = 1520.0
        let ctx = try context(Int(w), Int(h))
        ctx.setFillColor(CGColor(srgbRed: 0xE6 / 255, green: 0xE4 / 255, blue: 0xDE / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let scale = min((w - 256) / Double(window.width), (h - 192) / Double(window.height), 1)
        let fw = (Double(window.width) * scale).rounded(), fh = (Double(window.height) * scale).rounded()
        let rect = CGRect(x: ((w - fw) / 2).rounded(), y: ((h - fh) / 2).rounded(), width: fw, height: fh)
        let path = CGPath(roundedRect: rect, cornerWidth: 40, cornerHeight: 40, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 72, color: CGColor(gray: 0, alpha: 0.22))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(window, in: rect)
        return try XCTUnwrap(ctx.makeImage())
    }

    private static func halved(_ image: CGImage) throws -> CGImage {
        let ctx = try context(image.width / 2, image.height / 2)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width / 2, height: image.height / 2))
        return try XCTUnwrap(ctx.makeImage())
    }

    private static func context(_ w: Int, _ h: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
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

    // MARK: brand

    private func assertOnBrand(_ text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        if let r = text.range(of: #"\bAI\b|Shepetal|Wispr|Superwhisper|MacWhisper|Otter|Granola|Fireflies|Dragon|—|\b(?:Mail|Messages|Zoom|Teams|Slack)\b"#,
                              options: .regularExpression) {
            XCTFail("\(name) shows “\(text[r])”", file: file, line: line)
        }
    }

    /// The fictional lines carry no emoji and nothing off-brand, before any shot is drawn.
    func testFictionalTextIsOnBrand() throws {
        for l in Self.lines.flatMap({ [$0.app, $0.text] }) {
            XCTAssertFalse(l.unicodeScalars.contains { $0.properties.isEmojiPresentation }, "emoji in “\(l)”")
            assertOnBrand(l, "“\(l)”")
        }
    }
}
