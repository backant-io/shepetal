import AppKit
import Vision
import XCTest
import ShepetalCore
@testable import Shepetal

/// The shepetal window's shell in the shepetal UI: the title bar, the sidebar, Home, History (with its row tools
/// shown, as on hover) and Settings, drawn offscreen at 2x in Light and Dark for review (.github/workflows/screens.yml).
/// Skipped unless SHEPETAL_SCREENSHOTS names an output dir; run it like ScreenshotTests, whose rendering it copies:
///
///     SHEPETAL_HOME=$(mktemp -d) SHEPETAL_KEYCHAIN_SERVICE=io.backant.shepetal.test.screenshots \
///     SHEPETAL_SCREENSHOTS=<dir> swift test --filter ShepetalTests.HubShellScreenshotTests
///
/// No window is ordered front or made key, nothing activates the app or clicks a button, the pipeline gets a private
/// pasteboard, and defaults go to the argument domain (this process only). Every dictation is fictional.
@MainActor
final class HubShellScreenshotTests: XCTestCase {
    private var out: URL!
    private var root: URL!
    private var pasteboard: NSPasteboard!
    /// AppKit's own answer to "does this window look like the key window?", put back in tearDown.
    private var appKit: (method: Method, answer: IMP)?

    /// Locale.current is read once and then kept, so it is set before anything formats a date.
    nonisolated override class func setUp() {
        super.setUp()
        if ProcessInfo.processInfo.environment["SHEPETAL_SCREENSHOTS"] != nil {
            argue(["AppleLocale": "en_US", "AppleLanguages": ["en-US"]])
            if let reset = dlsym(dlopen(nil, RTLD_NOW), "_CFLocaleResetCurrent") {
                unsafeBitCast(reset, to: (@convention(c) () -> Void).self)()
            }
        }
    }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SHEPETAL_SCREENSHOTS"] else { throw XCTSkip("SHEPETAL_SCREENSHOTS is not set") }
        guard env["SHEPETAL_HOME"] == Paths.root.path, TokenStore.keychainService.hasPrefix("io.backant.shepetal.test.") else {
            throw NSError(domain: "HubShellScreenshotTests", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "set SHEPETAL_HOME and SHEPETAL_KEYCHAIN_SERVICE=io.backant.shepetal.test.* on the command line, or the Hub reads the real account"])
        }
        _ = NSApplication.shared
        // Drawn as the key window of the active app while none is key or on screen (see ScreenshotTests).
        let key = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, NSSelectorFromString("hasKeyAppearance")))
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        appKit = (key, method_setImplementation(key, imp_implementationWithBlock(yes)))
        out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        root = Paths.root.appendingPathComponent("hub-shell-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("io.backant.shepetal.test.\(UUID().uuidString)"))
    }

    override func tearDown() {
        if let a = appKit { method_setImplementation(a.method, a.answer) }
        appKit = nil
        NSApp?.appearance = nil
        pasteboard?.releaseGlobally()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: shots

    /// History: the search row, then each dictation with its app and time in mono and its tools.
    func testHubHistory() throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        for d in Self.dictations {
            let id = UUID().uuidString
            let wav = try pipeline.store.save([Float](repeating: 0, count: 16_000), id: id)
            try pipeline.history.add(HistoryEntry(id: id, createdAt: Self.oct(d.day, d.time), outcome: .inserted,
                                                  audioPath: wav.path, durationMs: d.text.split(separator: " ").count * 380,
                                                  rawText: d.text, text: d.text, app: d.app))
        }
        try shoot("20-hub-history", NSSize(width: 1120, height: 1100),
                  expect: ["History", "Search", "floor plan", "Copy text", "Show all"]) {
            let hub = self.hub(pipeline, tab: "history")
            let model: HubModel = try self.part(hub, "model")
            model.showAllTools = true
            model.reload()
            return (hub, try self.part(hub, "window"))
        }
    }

    /// Home, as tall as it is: the account, the status rows, the stats and Recent notices.
    func testHubHome() throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        try shoot("21-hub-home", NSSize(width: 1120, height: 1400), expect: ["Home", "All granted", "Recent notices"]) {
            let hub = self.hub(pipeline, tab: "home")
            return (hub, try self.part(hub, "window"))
        }
    }

    /// Settings, as tall as it is: every setting as a row.
    func testHubSettings() throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        try shoot("22-hub-settings", NSSize(width: 1120, height: 2600),
                  expect: ["Settings", "Always record meetings automatically", "Show words while you speak", "Open recordings folder"]) {
            let hub = self.hub(pipeline, tab: "settings")
            return (hub, try self.part(hub, "window"))
        }
    }

    /// The shell at its smallest, 640 x 420, on History.
    func testHubSmallest() throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        let d = Self.dictations[0]
        try pipeline.history.add(HistoryEntry(id: UUID().uuidString, createdAt: Self.oct(d.day, d.time), outcome: .inserted,
                                              audioPath: "", durationMs: 4000, rawText: d.text, text: d.text, app: d.app))
        try shoot("23-hub-smallest", NSSize(width: 640, height: 420), expect: ["History", "Dictionary"]) {
            let hub = self.hub(pipeline, tab: "history")
            (try self.part(hub, "model") as HubModel).reload()
            return (hub, try self.part(hub, "window"))
        }
    }

    // MARK: data (fictional: no real people, companies or products)

    /// The last one is long enough to clamp at four lines, so its Show all shows.
    private static let dictations: [(day: Int, time: String, app: String, text: String)] = [
        (22, "17:12", "Email", EmailFormat.apply("Hi Dana, thanks for the new floor plan. We'll go with the second option.")),
        (22, "16:48", "Chat", "Running ten minutes late, save me a seat by the window."),
        (22, "16:05", "Editor", "Newsletter ideas: an interview with the bakery on Elm Street, the community garden schedule, and a reminder about the book swap on the 14th."),
        (22, "14:02", "Editor", "Call the landlord about the heating, renew the parking permit, pick up the prints before 6."),
        (22, "11:37", "Chat", "Happy birthday, Lena! Dinner on Saturday is on me."),
        (21, "18:40", "Editor", "Notes from the garden meeting. Watering is on the first two weekends, and Niamh prints the new schedule by Monday. The shed needs a new lock before the winter, and the compost bins move to the north corner so the path stays clear. We close the garden on the 30th and open again in March. Priya asked for a sign-up sheet for the spring beds, so I'll put one by the gate. The tool library keeps the same hours, ten until two on Saturdays, and the hoses go into the shed after the last watering. Next meeting is the second Thursday of November."),
    ]

    private static func oct(_ day: Int, _ time: String) -> Date {
        let hm = time.split(separator: ":").map { Int($0)! }
        return Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hm[0], minute: hm[1]))!
    }

    // MARK: rendering (as ScreenshotTests)

    private func shoot(_ name: String, _ size: NSSize, expect: [String],
                       _ make: () throws -> (owner: AnyObject, window: NSWindow)) throws {
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let (owner, window) = try make()
            try withExtendedLifetime(owner) {
                let image = try render(window, size)
                try write(image, "\(name)-\(mode)-window@2x.png")
                let seen = try Self.text(in: image)
                for line in expect { XCTAssertTrue(seen.contains(line), "\(name) \(mode) does not show “\(line)”:\n\(seen)") }
                if let r = seen.range(of: #"Shepetal|—"#, options: .regularExpression) {
                    XCTFail("\(name) \(mode) shows “\(seen[r])”")
                }
            }
        }
    }

    /// Like `-key value` on the command line: this process only, never written to a defaults file.
    nonisolated private static func argue(_ values: [String: Any]) {
        let d = UserDefaults.standard
        d.setVolatileDomain(d.volatileDomain(forName: UserDefaults.argumentDomain).merging(values) { $1 },
                            forName: UserDefaults.argumentDomain)
    }

    private func hub(_ pipeline: Pipeline, tab: String) -> Hub {
        Self.argue(["hubTab": tab])
        return Hub(pipeline: pipeline, engine: { nil }, status: { ("On-device speech recognition (standard engine)", true) },
                   retention: { .keep }, setRetention: { _ in }, openPermissions: {}, loginItem: LoginItem(say: { _ in }),
                   openDictionary: {}, restoreFnKey: {})
    }

    private func part<T>(_ hub: Hub, _ label: String) throws -> T {
        try XCTUnwrap(Mirror(reflecting: hub).descendant(label) as? T, "Hub's \(label) was renamed: update this test")
    }

    /// The window's theme frame (title bar and traffic lights included) at 2x, with its 10 pt corners.
    private func render(_ window: NSWindow, _ size: NSSize) throws -> CGImage {
        window.setContentSize(size)
        for _ in 0..<3 {
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
        window.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
        let ctx = try XCTUnwrap(CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let all = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        ctx.addPath(CGPath(roundedRect: all, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.clip()
        ctx.setFillColor(background)
        ctx.fill(all)
        ctx.draw(try XCTUnwrap(rep.cgImage), in: all)
        return try XCTUnwrap(ctx.makeImage())
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
}
