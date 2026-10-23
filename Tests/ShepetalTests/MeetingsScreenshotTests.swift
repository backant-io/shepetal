import AppKit
import Vision
import XCTest
import ShepetalCore
import ShepetalSummary
import SwiftUI
@testable import Shepetal

/// The Meetings surfaces in shepetal UI, drawn offscreen at 2x in Light and Dark for the Screens workflow: the tab
/// (a finished meeting's summary, a live one's transcript, the Folders tab), the Meeting transcript window and the
/// meeting reminder. Skipped unless SHEPETAL_SCREENSHOTS names an output dir. Fictional data only. Helpers are
/// copied from ScreenshotTests (the shared file stays as it is). Nothing goes on screen, is made key or clicked.
@MainActor
final class MeetingsScreenshotTests: XCTestCase {
    private var out: URL!
    /// AppKit's own answer to "does this window look like the key window?", put back in tearDown.
    private var appKit: (method: Method, answer: IMP)?

    /// Locale.current is read once and then kept, so it is set before anything formats a date.
    nonisolated override class func setUp() {
        super.setUp()
        if ProcessInfo.processInfo.environment["SHEPETAL_SCREENSHOTS"] != nil {
            let d = UserDefaults.standard
            d.setVolatileDomain(d.volatileDomain(forName: UserDefaults.argumentDomain)
                .merging(["AppleLocale": "en_US", "AppleLanguages": ["en-US"]]) { $1 }, forName: UserDefaults.argumentDomain)
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
        let key = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, NSSelectorFromString("hasKeyAppearance")))
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        appKit = (key, method_setImplementation(key, imp_implementationWithBlock(yes)))
        out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let a = appKit { method_setImplementation(a.method, a.answer) }
        appKit = nil
        NSApp?.appearance = nil
    }

    // MARK: shots

    /// A finished meeting: Summary, Notes and Transcript as a segmented control, the summary's sections, action
    /// items with their owner and due date in mono.
    func testMeetingsSummary() throws {
        let records = try Self.meetings()
        try shoot("meetings-summary", Self.tabSize, expect: ["Action items", "Summary", "Transcript", "Search meetings"]) {
            let model = MeetingsModel(store: InMemoryMeetingStore(records), copy: { _ in })
            model.select(records[0].meeting.id)
            return (model, Self.window(MeetingsView(model: model)))
        }
    }

    /// A call that records: the Live mark in the title (the view's one signal mark), its transcript as Me and Others.
    func testMeetingsLive() throws {
        let live = Self.liveMeeting()
        try shoot("meetings-live", Self.tabSize, expect: ["Live", "Loud and clear"]) {
            let model = MeetingsModel(store: InMemoryMeetingStore(try Self.meetings() + [live]), copy: { _ in })
            model.select(live.meeting.id)
            return (model, Self.window(MeetingsView(model: model)))
        }
    }

    /// The Folders tab: the folder picker, New folder and the folder's menu.
    func testMeetingsFolders() throws {
        let records = try Self.meetings()
        try shoot("meetings-folders", Self.tabSize, expect: ["Folders", "Neighbours"]) {
            let store = InMemoryMeetingStore(records)
            let folder = try store.createFolder("Neighbours")
            try store.setFolders([folder.id], for: records[1].meeting.id)
            let model = MeetingsModel(store: store, copy: { _ in })
            model.tab = .folders
            model.openFolder(folder.id)
            return (model, Self.window(MeetingsView(model: model)))
        }
    }

    /// No meetings yet: the empty pane.
    func testMeetingsEmpty() throws {
        try shoot("meetings-empty", Self.tabSize, expect: ["No meetings yet"]) {
            let model = MeetingsModel(store: InMemoryMeetingStore(), copy: { _ in })
            return (model, Self.window(MeetingsView(model: model)))
        }
    }

    /// The window that opens after a call: summary, action items and the transcript as Me and Others.
    func testMeetingsTranscriptWindow() throws {
        let office = try Self.meetings()[0]
        try shoot("meetings-transcript-window", NSSize(width: 640, height: 704), expect: ["Copy summary", "Action items"]) {
            let w = MeetingTranscriptWindow(model: MeetingsModel(store: InMemoryMeetingStore([office]), copy: { _ in }),
                                            open: { _ in }, panel: TranscriptPanel())
            w.model.select(office.meeting.id)  // never w.show(): it orders the panel front
            return (w, w.panel)
        }
    }

    /// The meeting reminder: Not now, and Record as the live signal keycap. And the update prompt on the same card.
    func testMeetingReminder() throws {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        for (name, expect, make) in [
            ("meetings-reminder", ["Meeting detected", "Not now", "Record"], {
                MeetingCard(screen: { screen }, present: { _ in }, onRecord: {}, onNotNow: {})
            }),
            ("meetings-update-prompt", ["Later", "Install Now"], {
                MeetingCard.update(screen: { screen }, present: { _ in }, onInstall: {}, onLater: {})
            }),
        ] as [(String, [String], () -> MeetingCard)] {
            try shoot(name, nil, expect: expect) {
                let card = make()
                card.show("Video call")  // `present` only counts: the panel stays off screen
                return (card, card.panel)
            }
        }
    }

    // MARK: data (fictional: no real people, companies or products)

    private static let tabSize = NSSize(width: 1000, height: 680)

    private static let office: [(Speaker, Double, String)] = [
        (.others, 4, "Hi, everyone. Thanks for making time."),
        (.me, 9, "Glad we found a slot."),
        (.others, 15, "We have two things today: the floor plan for the new office and the movers, before the old lease ends on the 20th."),
        (.others, 160, "Dana sent the new floor plan, and the second option gives every team a quiet room."),
        (.me, 610, "So we use the second option, and we ask the landlord for the kitchen wall in writing."),
        (.others, 980, "Tomasz got two quotes, and the cheaper movers only come on a Saturday morning."),
        (.others, 1385, "Sure, I'll book the movers by Friday and send everyone the time slot."),
        (.me, 1520, "I'll write to the landlord about the kitchen wall tomorrow."),
        (.others, 1690, "Yes, I'll order the desk lamps by next Wednesday."),
    ]

    private static let garden: [(Speaker, Double, String)] = [
        (.others, 6, "Thanks for joining. Let's look at the garden schedule for November."),
        (.me, 140, "I can take the watering on the first two weekends."),
        (.others, 610, "We decided to close the garden on the 30th for the winter."),
        (.others, 1560, "Sure, I'll print the schedule by Monday."),
    ]

    private static let liveLines: [(Speaker, Double, String)] = [
        (.others, 5, "Morning. Can everyone hear me okay?"),
        (.me, 12, "Loud and clear. Shall we start with the newsletter?"),
        (.others, 27, "Lena finished the interview with the bakery on Elm Street, and it reads really well."),
        (.me, 49, "Great. Then it goes first, and the garden schedule goes second."),
    ]

    private static func meetings() throws -> [MeetingRecord] {
        let summarizer = try MeetingSummarizer()
        return [(office, oct(22, "14:00"), 31), (garden, oct(20, "16:00"), 45)].map { lines, start, minutes in
            let segments = segments(lines)
            return MeetingRecord(meeting: Meeting(id: UUID().uuidString, app: MeetingRecorder.manualApp, startedAt: start,
                                                  endedAt: start.addingTimeInterval(Double(minutes) * 60),
                                                  meAudioPath: "", othersAudioPath: ""),
                                 segments: segments, summary: summarizer.summarize(segments))
        }
    }

    private static func liveMeeting() -> MeetingRecord {
        MeetingRecord(meeting: Meeting(id: UUID().uuidString, app: MeetingRecorder.manualApp,
                                       startedAt: Date().addingTimeInterval(-4 * 60), meAudioPath: "", othersAudioPath: ""),
                      segments: segments(liveLines))
    }

    private static func segments(_ lines: [(Speaker, Double, String)]) -> [Segment] {
        lines.map { Segment(speaker: $0.0, start: $0.1, end: $0.1 + Double($0.2.split(separator: " ").count) * 0.4 + 1, text: $0.2) }
    }

    private static func oct(_ day: Int, _ time: String) -> Date {
        let hm = time.split(separator: ":").map { Int($0)! }
        return Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hm[0], minute: hm[1]))!
    }

    // MARK: rendering

    /// An offscreen window holding `view` under a transparent title bar, as the Hub's content.
    private static func window<V: View>(_ view: V) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: tabSize),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.title = "Meetings"
        w.contentView = NSHostingView(rootView: view)
        return w
    }

    /// Light, then Dark: `make` builds the window in that appearance; it is drawn, written and read back. A nil
    /// size keeps the window's own (the reminder sizes itself to its content).
    private func shoot(_ name: String, _ size: NSSize?, expect: [String],
                       _ make: () throws -> (owner: AnyObject, window: NSWindow)) throws {
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let (owner, window) = try make()
            try withExtendedLifetime(owner) {
                let image = try render(window, size)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: out.appendingPathComponent("\(name)-\(mode)@2x.png"))
                let seen = try Self.text(in: image)
                for line in expect { XCTAssertTrue(seen.contains(line), "\(name) \(mode) does not show “\(line)”:\n\(seen)") }
                if let r = seen.range(of: #"\bAI\b|Shepetal|—|\b(?:Mail|Messages|Zoom|Teams|Slack)\b"#, options: .regularExpression) {
                    XCTFail("\(name) \(mode) shows “\(seen[r])”")
                }
            }
        }
    }

    /// The window's frame view (title bar included) at 2x, on its window background; a borderless panel keeps its
    /// transparent corners.
    private func render(_ window: NSWindow, _ size: NSSize?) throws -> CGImage {
        if let size { window.setContentSize(size) }
        for _ in 0..<3 {  // SwiftUI restyles and fills its lists on the next passes
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        XCTAssertFalse(window.isVisible, "a screenshot must not put the window on screen")
        XCTAssertNil(NSApp.keyWindow, "a screenshot must not make a window key")
        let frame = try XCTUnwrap(window.contentView?.superview, "the window has no frame view")
        let b = frame.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width) * 2, pixelsHigh: Int(b.height) * 2,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = b.size
        frame.cacheDisplay(in: b, to: rep)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let all = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        if window.styleMask.contains(.titled) {
            var background = CGColor(gray: 1, alpha: 1)
            window.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
            ctx.addPath(CGPath(roundedRect: all, cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.clip()
            ctx.setFillColor(background)
            ctx.fill(all)
        }
        ctx.draw(try XCTUnwrap(rep.cgImage), in: all)
        return try XCTUnwrap(ctx.makeImage())
    }

    private static func text(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
