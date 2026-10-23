import AppKit
import Vision
import XCTest
import ShepetalCore
import ShepetalSummary
@testable import Shepetal

/// Launch screenshots: the real Hub and Meeting transcript windows with fictional data, drawn offscreen at 2x.
/// Skipped unless SHEPETAL_SCREENSHOTS names an output dir, so `swift test` and CI never write a file. Each shot
/// is written in Light and Dark, as the raw window (`NN-name-light-window@2x.png`) and centred on the site's
/// #E6E4DE at 1270 x 760 (`NN-name-light.png`).
///
/// Building the Hub reads the account (Keychain and account.json), and Paths.root is a static let, so run this
/// class alone with both env vars set before the process starts:
///
///     SHEPETAL_HOME=$(mktemp -d) SHEPETAL_KEYCHAIN_SERVICE=io.backant.shepetal.test.screenshots \
///     SHEPETAL_SCREENSHOTS=<dir> swift test --filter ShepetalTests.ScreenshotTests
///
/// No window is ordered front or made key and nothing activates the app or clicks a button; the pipeline gets a
/// private pasteboard, and the meetings models write the clipboard only from their Copy buttons. The brand keeps 🤫 out of screenshots, so no shot shows the
/// menu, Home, Settings or the welcome window: they draw it or mention it.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var out: URL!
    private var root: URL!
    private var pasteboard: NSPasteboard!
    private var tz: String?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SHEPETAL_SCREENSHOTS"] else { throw XCTSkip("SHEPETAL_SCREENSHOTS is not set") }
        guard env["SHEPETAL_HOME"] == Paths.root.path, TokenStore.keychainService.hasPrefix("io.backant.shepetal.test.") else {
            throw NSError(domain: "ScreenshotTests", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "set SHEPETAL_HOME and SHEPETAL_KEYCHAIN_SERVICE=io.backant.shepetal.test.* on the command line, or the Hub reads the real account"])
        }
        _ = NSApplication.shared  // a window needs the app object, even in the test bundle
        out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        root = Paths.root.appendingPathComponent("screenshots-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: .init("io.backant.shepetal.test.\(UUID().uuidString)"))
        // The live meeting started 18 minutes ago by the real clock: a zone where now reads 09:48 makes it a
        // morning call whenever this runs. Every other date is built in the same zone, so it reads as written.
        tz = getenv("TZ").map { String(cString: $0) }
        let utc = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date())
        var minutes = 9 * 60 + 48 - (utc.hour! * 60 + utc.minute!)
        if minutes < -12 * 60 { minutes += 24 * 60 } else if minutes > 14 * 60 { minutes -= 24 * 60 }
        setZone(String(format: "GMT%@%02d:%02d", minutes < 0 ? "-" : "+", abs(minutes) / 60, abs(minutes) % 60))
    }

    override func tearDown() {
        if out != nil { setZone(tz) }
        NSApp?.appearance = nil
        UserDefaults.standard.removeObject(forKey: "hubTab")
        pasteboard?.releaseGlobally()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: shots

    /// Everything said lands as text in an app and stays on the Mac, with Copy, Play and Re-transcribe on each row.
    func testHistory() throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        for d in Self.dictations {
            let id = UUID().uuidString
            let wav = try pipeline.store.save([Float](repeating: 0, count: 16_000), id: id)  // Play is enabled
            try pipeline.history.add(HistoryEntry(id: id, createdAt: Self.oct(d.day, d.time), outcome: .inserted,
                                                  audioPath: wav.path, durationMs: d.text.split(separator: " ").count * 380,
                                                  rawText: d.text, text: d.text, app: d.app))
        }
        try shoot("01-history", Self.hubSize, expect: ["floor plan", "Running ten minutes late", "plumber comes"]) {
            let hub = self.hub(pipeline, tab: "history")
            // Hub.show() loads the rows, and it would put the window on screen.
            (try self.part(hub, "model") as HubModel).reload()
            return (hub, try self.part(hub, "window"))
        }
    }

    /// A finished meeting: the summary the app's own summarizer wrote, with decisions and owned action items.
    func testMeetingSummary() throws {
        let records = try Self.meetings()
        let office = records[0]
        let summary = try XCTUnwrap(office.summary)
        let last = try XCTUnwrap(summary.actionItems.last, "the office call has action items")
        try shoot("02-meeting-summary", Self.hubSize, expect: ["Action items", String(last.task.prefix(24))]) {
            let hub = self.hub(try Pipeline(root: self.root, pasteboard: self.pasteboard), tab: "meetings",
                               meetings: InMemoryMeetingStore(records))
            (try self.part(hub, "meetings") as MeetingsModel).select(office.meeting.id)
            return (hub, try self.part(hub, "window"))
        }
    }

    /// A call still recording: its transcript, split into Me and Others, as it is written.
    func testMeetingLive() throws {
        let live = Self.liveMeeting()
        try shoot("03-meeting-live", Self.hubSize, expect: ["Loud and clear", "Live", "at 9:30"]) {
            let hub = self.hub(try Pipeline(root: self.root, pasteboard: self.pasteboard), tab: "meetings",
                               meetings: InMemoryMeetingStore(try Self.meetings() + [live]))
            (try self.part(hub, "meetings") as MeetingsModel).select(live.meeting.id)
            return (hub, try self.part(hub, "window"))
        }
    }

    /// Names and terms come out spelled right; a replacement types an address.
    func testDictionary() throws {
        let pipeline = try Pipeline(root: root, pasteboard: pasteboard)
        try (Vocabulary.header + Self.dictionary.joined(separator: "\n") + "\n")
            .write(to: pipeline.dictionary, atomically: true, encoding: .utf8)
        try shoot("04-dictionary", Self.hubSize, expect: ["Saoirse", "maya@example.com", "e.g."]) {
            let hub = self.hub(pipeline, tab: "dictionary")
            (try self.part(hub, "dictionary") as DictionaryModel).reload()  // the tab's onAppear may not run offscreen
            return (hub, try self.part(hub, "window"))
        }
    }

    /// The window that opens by itself after a call: summary, action items and transcript in one place.
    func testMeetingTranscriptWindow() throws {
        let office = try Self.meetings()[0]
        try shoot("05-meeting-transcript-window", NSSize(width: 600, height: 760), expect: ["Copy summary", "Action items"]) {
            let w = MeetingTranscriptWindow(model: MeetingsModel(store: InMemoryMeetingStore([office]), copy: { _ in }),
                                            open: { _ in }, panel: TranscriptPanel())
            w.model.select(office.meeting.id)  // never w.show(): it orders the panel front
            return (w, w.panel)
        }
    }

    // MARK: data (fictional: no real people, companies or products)

    private static let hubSize = NSSize(width: 1120, height: 720)

    private static let dictations: [(day: Int, time: String, app: String, text: String)] = [
        (22, "17:12", "Mail", EmailFormat.apply("Hi Dana, thanks for sending the new floor plan. The second option works for us, as long as the kitchen wall can move by half a meter. Could we go through it on Thursday at 10? Best regards, Maya")),
        (22, "16:48", "Messages", "Running ten minutes late, save me a seat by the window."),
        (22, "16:05", "Notes", "Newsletter ideas: an interview with the bakery on Elm Street, the community garden schedule, and a reminder about the book swap on the 14th."),
        (22, "15:20", "Mail", EmailFormat.apply("Hi Tomasz, the movers can come on Saturday morning. Could you book them by Friday and share the time slot with everyone? Thanks, Maya")),
        (22, "14:02", "Notes", "Call the landlord about the heating, renew the parking permit, pick up the prints before 6."),
        (22, "11:37", "Messages", "Happy birthday, Lena! Dinner on Saturday is on me."),
        (22, "09:15", "Notes", "Three things for today: finish the budget draft, reply to Priya about the venue, and book the train for Tuesday."),
        (21, "18:40", "Messages", "Can you grab oat milk on the way home? We're out."),
        (21, "16:25", "Mail", EmailFormat.apply("Hi Priya, the hall is free on the 14th from ten until four. Shall I put us down for the book swap? Thanks, Maya")),
        (21, "12:10", "Notes", "Garden schedule: watering on the first two weekends, closed for the winter from the 30th."),
        (21, "09:05", "Messages", "Good morning! The plumber comes between 9 and 11, so I'll be home until noon."),
    ]

    private static let dictionary = [
        "*Maya Lindqvist", "*Tomasz Wierzbicki", "Saoirse", "Niamh", "Aoife", "Siobhán", "Okonkwo", "Nguyen",
        "Alder Street", "Elm Street Bakery", "stand up => stand-up",
        "my email => maya@example.com", "my address => 12 Alder Street", "Q four => Q4", "e g => e.g.",  // example.com is reserved
    ]

    private static let office: [(Speaker, Double, String)] = [
        (.others, 4, "This is the planning call for the office move, so let's go through the floor plan and the movers."),
        (.me, 95, "Sounds good. The lease for the old office ends on the 20th, so we have a week of overlap."),
        (.others, 260, "Dana sent the new floor plan, and the second option gives every team a quiet room."),
        (.others, 420, "The landlord is fine with small changes to the walls if we ask two weeks ahead."),
        (.me, 610, "Then let's use the second option and ask for the kitchen wall in writing."),
        (.others, 700, "Agreed. We keep the old phone numbers."),
        (.me, 905, "What about the movers?"),
        (.others, 980, "Tomasz got two quotes, and the cheaper movers only come on a Saturday morning."),
        (.me, 1190, "A Saturday works for me."),
        (.others, 1300, "Tomasz, can you book the movers for that Saturday?"),
        (.others, 1385, "Sure, I'll book the movers by Friday and share the time slot with everyone."),
        (.me, 1520, "I'll write to the landlord about the kitchen wall tomorrow."),
        (.others, 1610, "Dana, could you order the new desk lamps?"),
        (.others, 1690, "Yes, I'll order the desk lamps by next Wednesday."),
        (.me, 1800, "Great, that covers it for today."),
    ]

    private static let garden: [(Speaker, Double, String)] = [
        (.others, 6, "Thanks for joining. Let's look at the garden schedule for November."),
        (.me, 140, "I can take the watering on the first two weekends."),
        (.others, 610, "We decided to close the garden on the 30th for the winter."),
        (.others, 1500, "Niamh, can you print the new schedule by Monday?"),
        (.others, 1560, "Sure, I'll print the schedule by Monday."),
    ]

    private static let budget: [(Speaker, Double, String)] = [
        (.others, 5, "Let's go through the budget draft for the book swap."),
        (.me, 210, "The hall costs a little more this year, but the snacks are donated."),
        (.others, 640, "Then we keep the entry free."),
        (.me, 1300, "I'll send the final numbers on Friday."),
    ]

    private static let liveLines: [(Speaker, Double, String)] = [
        (.others, 845, "Morning! Can everyone hear me okay?"),
        (.me, 862, "Loud and clear. Shall we start with the newsletter?"),
        (.others, 880, "Lena finished the interview with the bakery on Elm Street, and it reads really well."),
        (.me, 910, "Great. Then it goes first, and the garden schedule goes second."),
        (.others, 940, "Priya asked if we can move the book swap to the 14th, because the hall is booked on the 7th."),
        (.me, 975, "The 14th works. I'll update the date in the draft today."),
        (.others, 1010, "Perfect. The cover photos are due on Thursday."),
        (.me, 1050, "Then the newsletter goes out on Friday morning."),
    ]

    /// The office-move call first, then two older ones for the sidebar. "Manual" is what MeetingRecorder writes for
    /// a meeting started from the menu; a detected one would carry a real product's name. Each summary is the
    /// app's own non-LLM summarizer run on the transcript, as MeetingTranscriber does, never written by hand.
    private static func meetings() throws -> [MeetingRecord] {
        let summarizer = try MeetingSummarizer()
        return [(office, oct(22, "14:00"), 31), (garden, oct(20, "16:00"), 45), (budget, oct(17, "11:00"), 25)]
            .map { lines, start, minutes in
                let segments = segments(lines)
                return MeetingRecord(meeting: meeting(start, minutes: minutes), segments: segments,
                                     summary: summarizer.summarize(segments))
            }
    }

    /// Still recording: no end, no summary yet. It started 18 minutes ago, by the real clock the tab reads.
    private static func liveMeeting() -> MeetingRecord {
        MeetingRecord(meeting: Meeting(id: UUID().uuidString, app: MeetingRecorder.manualApp,
                                       startedAt: Date().addingTimeInterval(-18 * 60), meAudioPath: "", othersAudioPath: ""),
                      segments: segments(liveLines))
    }

    private static func meeting(_ start: Date, minutes: Int) -> Meeting {
        Meeting(id: UUID().uuidString, app: MeetingRecorder.manualApp, startedAt: start,
                endedAt: start.addingTimeInterval(Double(minutes) * 60), meAudioPath: "", othersAudioPath: "")
    }

    private static func segments(_ lines: [(Speaker, Double, String)]) -> [Segment] {
        lines.map { Segment(speaker: $0.0, start: $0.1, end: $0.1 + Double($0.2.split(separator: " ").count) * 0.4 + 1, text: $0.2) }
    }

    private static func oct(_ day: Int, _ time: String) -> Date {
        let hm = time.split(separator: ":").map { Int($0)! }
        return Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hm[0], minute: hm[1]))!
    }

    // MARK: rendering

    /// Light, then Dark: `make` builds the window in that appearance; it is drawn, written and read back.
    private func shoot(_ name: String, _ size: NSSize, expect: [String],
                       _ make: () throws -> (owner: AnyObject, window: NSWindow)) throws {
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let (owner, window) = try make()
            try withExtendedLifetime(owner) {
                let image = try render(window, size)
                try write(image, "\(name)-\(mode)-window@2x.png")
                try write(Self.framed(image), "\(name)-\(mode).png")
                // A placeholder, an empty list or a clipped pane would not show these.
                let seen = try Self.text(in: image)
                for line in expect { XCTAssertTrue(seen.contains(line), "\(name) \(mode) does not show “\(line)”:\n\(seen)") }
                assertOnBrand(seen, "\(name) \(mode)")
            }
        }
    }

    private func setZone(_ name: String?) {
        if let name { setenv("TZ", name, 1) } else { unsetenv("TZ") }
        tzset()
        NSTimeZone.resetSystemTimeZone()
    }

    private func hub(_ pipeline: Pipeline, tab: String, meetings: MeetingStoring = InMemoryMeetingStore()) -> Hub {
        UserDefaults.standard.set(tab, forKey: "hubTab")  // the test runner's defaults, never io.backant.shepetal
        return Hub(pipeline: pipeline, engine: { nil }, status: { ("On-device speech recognition (standard engine)", true) },
                   retention: { .keep }, setRetention: { _ in }, openPermissions: {}, loginItem: LoginItem(say: { _ in }),
                   openDictionary: {}, restoreFnKey: {}, meetingStore: meetings)
    }

    private func part<T>(_ hub: Hub, _ label: String) throws -> T {
        try XCTUnwrap(Mirror(reflecting: hub).descendant(label) as? T, "Hub's \(label) was renamed: update this test")
    }

    /// The window's theme frame (title bar and traffic lights included) at 2x, on the window background of its
    /// appearance, so a translucent sidebar or title bar shows what it shows over the window, not transparency.
    private func render(_ window: NSWindow, _ size: NSSize) throws -> CGImage {
        window.setContentSize(size)
        for _ in 0..<3 {  // SwiftUI restyles and fills its lists on the next passes
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        XCTAssertFalse(window.isVisible, "a screenshot must not put the window on screen")
        XCTAssertFalse(window.isKeyWindow)
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
        ctx.setFillColor(background)
        ctx.fill(all)
        ctx.draw(try XCTUnwrap(rep.cgImage), in: all)
        return try XCTUnwrap(ctx.makeImage())
    }

    /// 1270 x 760 (Product Hunt's gallery size): the window fitted inside 64 px side and 48 px top and bottom margins,
    /// centred on #E6E4DE, with the brand's 20 px screenshot-frame corners and one soft shadow. Nothing inside changes.
    private static func framed(_ window: CGImage) throws -> CGImage {
        let w = 1270.0, h = 760.0
        let ctx = try context(Int(w), Int(h))
        ctx.setFillColor(CGColor(srgbRed: 0xE6 / 255, green: 0xE4 / 255, blue: 0xDE / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let scale = min((w - 128) / Double(window.width), (h - 96) / Double(window.height))
        let fw = (Double(window.width) * scale).rounded(), fh = (Double(window.height) * scale).rounded()
        let rect = CGRect(x: ((w - fw) / 2).rounded(), y: ((h - fh) / 2).rounded(), width: fw, height: fh)
        let path = CGPath(roundedRect: rect, cornerWidth: 20, cornerHeight: 20, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 36, color: CGColor(gray: 0, alpha: 0.22))
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

    /// What the shot shows, read back from the pixels: the name in lowercase, no "AI", no competitor.
    private func assertOnBrand(_ text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        if let r = text.range(of: #"\bAI\b|Shepetal|Wispr|Superwhisper|MacWhisper|Otter|Granola|Fireflies|Dragon"#,
                              options: .regularExpression) {
            XCTFail("\(name) shows “\(text[r])”", file: file, line: line)
        }
    }

    /// Every fictional line, before any shot is drawn: no emoji (Apple's artwork on a Mac) and nothing off-brand.
    func testFictionalTextIsOnBrand() throws {
        let said: [String] = [Self.office, Self.garden, Self.budget, Self.liveLines].flatMap { $0.map(\.2) }
        let typed: [String] = Self.dictations.flatMap { [$0.app, $0.text] }
        for l in typed + Self.dictionary + said {
            XCTAssertFalse(l.unicodeScalars.contains { $0.properties.isEmojiPresentation }, "emoji in “\(l)”")
            assertOnBrand(l, "“\(l)”")
        }
    }
}
