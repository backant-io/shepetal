import AppKit
import SwiftUI
import Vision
import XCTest
import ShepetalCore
@testable import Shepetal

/// Review shots of the indicator, the menu bar icon, onboarding and the small windows (Shortcuts, the notes, What's
/// new, the share card), drawn offscreen at 2x in Concrete (light) and Night (dark), with fictional data only. Skipped
/// unless SHEPETAL_SCREENSHOTS names an output dir, like ScreenshotTests, whose helpers these are copied from:
///
///     SHEPETAL_HOME=$(mktemp -d) SHEPETAL_KEYCHAIN_SERVICE=io.backant.shepetal.test.screenshots \
///     SHEPETAL_SCREENSHOTS=<dir> swift test --filter ShepetalTests.MenuIndicatorOnboardingScreenshotTests
///
/// No window is ordered front or made key, nothing activates the app or clicks a button, and nothing reads the
/// account: the sign-in step is never drawn. Each file is `NN-name-light-window@2x.png` and `...-dark-...`.
@MainActor
final class MenuIndicatorOnboardingScreenshotTests: XCTestCase {
    private var out: URL!
    private var root: URL!
    /// AppKit's own answer to "does this window look like the key window?", put back in tearDown.
    private var appKit: (method: Method, answer: IMP)?

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHEPETAL_SCREENSHOTS"] else { throw XCTSkip("SHEPETAL_SCREENSHOTS is not set") }
        _ = NSApplication.shared  // a window needs the app object, even in the test bundle
        let key = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, NSSelectorFromString("hasKeyAppearance")))
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        appKit = (key, method_setImplementation(key, imp_implementationWithBlock(yes)))
        out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("screenshots-small-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let a = appKit { method_setImplementation(a.method, a.answer) }
        appKit = nil
        NSApp?.appearance = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: shots

    /// Every state of the indicator at its real size, named beside it, and the menu bar icon at rest and recording.
    func testIndicator() throws {
        try shoot("20-indicator", NSSize(width: 360, height: 300), layers: true,
                  expect: ["Recording", "Hands-free", "Writing", "A note", "Mic is off"]) { try self.indicatorPlate() }
    }

    private func indicatorPlate() throws -> (owner: AnyObject, window: NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "Indicator"
        window.backgroundColor = SH.bg.nsColor
        let plate = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
        plate.wantsLayer = true
        var indicators: [Indicator] = []
        let states: [(name: String, mode: Indicator.Mode, note: String?)] = [
            ("Ready", .idle, nil), ("Recording", .recording, nil), ("Hands-free", .handsFree, nil),
            ("Writing", .processing, nil), ("A note", .error, "Mic is off"),
        ]
        for (n, state) in states.enumerated() {
            let y: CGFloat = 260 - CGFloat(n) * 40
            let i = Indicator(screen: { .zero }, present: { _ in })
            i.set(state.mode)
            if let note = state.note { i.show(note, seconds: 60) }
            indicators.append(i)
            let view = try XCTUnwrap(i.panel.contentView)
            i.panel.contentView = NSView()
            view.setFrameOrigin(NSPoint(x: 120, y: y))
            plate.addSubview(view)
            plate.addSubview(Self.caption(state.name, at: NSPoint(x: 24, y: y)))
        }
        for (n, live) in [false, true].enumerated() {
            let y: CGFloat = 260 - CGFloat(states.count + n) * 40 + 2
            let icon = NSImageView(image: MenuModel.statusIcon(live: live))
            icon.frame = NSRect(x: 120, y: y, width: 18, height: 18)
            plate.addSubview(icon)
            plate.addSubview(Self.caption(live ? "Menu bar, live" : "Menu bar", at: NSPoint(x: 24, y: y)))
        }
        window.contentView = plate
        return (indicators as NSArray, window)
    }

    /// Step 1: each permission with why in one sentence and Open settings, Continue as the one primary keycap.
    func testOnboardingPermissions() throws {
        try shoot("21-onboarding-permissions", NSSize(width: 560, height: 560),
                  expect: ["Permissions", "Accessibility lets shepetal", "Continue"]) {
            let w = Onboarding(allowRequests: false, engine: { (true, "") }, loginItem: LoginItem(say: { _ in }))
            return (w, try XCTUnwrap(w.window))
        }
    }

    /// The last step: the fn key hint, a dictation that landed, Start at login, Done.
    func testOnboardingTryIt() throws {
        try shoot("22-onboarding-try-it", NSSize(width: 560, height: 420), expect: ["Try it", "It works", "Done"]) {
            let w = Onboarding(allowRequests: false, engine: { (true, "") }, loginItem: LoginItem(say: { _ in }))
            let model = try XCTUnwrap(Mirror(reflecting: w).descendant("model") as? OnboardingModel,
                                      "Onboarding's model was renamed: update this test")
            _ = model.flow.next(requiredGranted: true, signedIn: false)
            model.tried = "Lunch on Friday works for me."
            return (w, try XCTUnwrap(w.window))
        }
    }

    func testShortcuts() throws {
        try shoot("23-shortcuts", NSSize(width: 520, height: 480), expect: ["Shortcuts", "Paste last transcript", "Reset to defaults"]) {
            let w = ShortcutsWindow(tap: FnTap())
            return (w, try XCTUnwrap(w.window))
        }
    }

    func testNotes() throws {
        try shoot("24-notes", NSSize(width: 760, height: 480), expect: ["Pinned", "Garden plan", "Book swap"]) {
            let model = NotesModel(store: try NoteStore(path: self.root.appendingPathComponent("notes-\(UUID().uuidString).sqlite")))
            var open = ""
            for (title, body, pinned) in Self.notes {
                let id = model.create().id
                model.edit(id, title: title, body: body)
                if pinned { model.setPinned(id, true) }
                if open.isEmpty { open = id }
            }
            model.flushAll()
            let tab = NoteTab()
            tab.title = NotesWindow.title(model.note(open))
            tab.contentView = NSHostingView(rootView: NoteView(model: model, id: open, windows: nil))
            return (model, tab)
        }
    }

    func testWhatsNew() throws {
        try shoot("25-whats-new", NSSize(width: 480, height: 400), expect: ["What's new in shepetal", "0.1.0"]) {
            let w = WhatsNewWindow()
            return (w, try XCTUnwrap(w.window))
        }
    }

    /// The share card is fixed in Night colors, so the light and dark shots are the same card.
    func testShareCard() throws {
        try shoot("26-share-card", ShareCard.size, expect: ["words dictated", "Write at the speed of thought."]) {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: ShareCard.size), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.title = "Share card"
            window.contentView = NSHostingView(rootView: ShareCardView(stats: ShareStats(words: 12_340, wpm: 142, streak: 7)))
            return (window, window)
        }
    }

    // MARK: data (fictional)

    private static let notes: [(String, String, Bool)] = [
        ("Garden plan", "Watering on the first two weekends.\nClose the garden on the 30th for the winter.", false),
        ("Book swap", "Hall booked for the 14th, from ten until four.\nAsk Priya about tables.", true),
        ("Groceries", "Oat milk, lemons, bread.", false),
    ]

    private static func caption(_ text: String, at origin: NSPoint) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = SH.appSmall.nsFont
        f.textColor = SH.text.nsColor
        f.sizeToFit()
        f.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + (Indicator.size - f.frame.height) / 2))
        return f
    }

    // MARK: rendering (copied from ScreenshotTests)

    /// Light, then Dark: `make` builds the window in that appearance; it is drawn, written and read back.
    private func shoot(_ name: String, _ size: NSSize, layers: Bool = false, expect: [String],
                       _ make: () throws -> (owner: AnyObject, window: NSWindow)) throws {
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let (owner, window) = try make()
            try withExtendedLifetime(owner) {
                let image = try layers ? renderLayers(window, size) : render(window, size)
                try write(image, "\(name)-\(mode)-window@2x.png")
                let seen = try Self.text(in: image)
                for line in expect { XCTAssertTrue(seen.contains(line), "\(name) \(mode) does not show “\(line)”:\n\(seen)") }
                assertOnBrand(seen, "\(name) \(mode)")
            }
        }
    }

    /// The window's theme frame (title bar and traffic lights included) at 2x, on the window background of its
    /// appearance. Outside its 10 pt corners it is transparent, like a window.
    private func render(_ window: NSWindow, _ size: NSSize) throws -> CGImage {
        window.setContentSize(size)
        for _ in 0..<3 {  // SwiftUI restyles and fills its lists on the next passes
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        XCTAssertFalse(window.isVisible, "a screenshot must not put the window on screen")
        XCTAssertNil(NSApp.keyWindow, "a screenshot must not make a window key")
        let frame = try XCTUnwrap(window.contentView?.superview, "the window has no theme frame")
        let b = frame.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width) * 2, pixelsHigh: Int(b.height) * 2,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = b.size
        frame.cacheDisplay(in: b, to: rep)
        var background = CGColor(gray: 1, alpha: 1)
        window.effectiveAppearance.performAsCurrentDrawingAppearance { background = window.backgroundColor.cgColor }
        let ctx = try Self.context(rep.pixelsWide, rep.pixelsHigh)
        let all = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        ctx.addPath(CGPath(roundedRect: all, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.clip()
        ctx.setFillColor(background)
        ctx.fill(all)
        ctx.draw(try XCTUnwrap(rep.cgImage), in: all)
        return try XCTUnwrap(ctx.makeImage())
    }

    /// The content view's layer tree at 2x, for views whose look lives in their layers (the indicator's label plate
    /// and its pulsing ring), on the window background.
    private func renderLayers(_ window: NSWindow, _ size: NSSize) throws -> CGImage {
        window.setContentSize(size)
        let view = try XCTUnwrap(window.contentView)
        view.wantsLayer = true
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            view.layoutSubtreeIfNeeded()
            view.display()
            CATransaction.flush()
        }
        XCTAssertFalse(window.isVisible, "a screenshot must not put the window on screen")
        let layer = try XCTUnwrap(view.layer)
        let ctx = try Self.context(Int(size.width) * 2, Int(size.height) * 2)
        var background = CGColor(gray: 1, alpha: 1)
        window.effectiveAppearance.performAsCurrentDrawingAppearance { background = window.backgroundColor.cgColor }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
        ctx.scaleBy(x: 2, y: 2)
        layer.render(in: ctx)
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

    /// What the shot shows, read back from the pixels: the name in lowercase, no "AI", no em dash, no other product.
    private func assertOnBrand(_ text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        if let r = text.range(of: #"\bAI\b|Shepetal|Wispr|Superwhisper|MacWhisper|Otter|Granola|Fireflies|Dragon|—|\b(?:Mail|Messages|Zoom|Teams|Slack)\b"#,
                              options: .regularExpression) {
            XCTFail("\(name) shows “\(text[r])”", file: file, line: line)
        }
    }
}
