import XCTest
import ShepetalCore
@testable import ShepetalSummary

/// Ask about meetings (F73): rules sort the question, and the answer is quoted from the transcript or the stored
/// summary, never written. Most cases run on the real fixture meetings in summarize/fixtures, with the summary the
/// summarizer writes for them, so a change in either shows up here.
final class MeetingAnswersTests: XCTestCase {
    static let repo = ShepetalSummaryTests.repo

    /// A fixture as the app would hold it: one segment per line, 10 s apart, named speakers, and the summarizer's summary.
    func fixture(_ name: String) throws -> MeetingAnswers.Doc {
        let text = try String(contentsOf: Self.repo.appendingPathComponent("summarize/fixtures/\(name).txt"), encoding: .utf8)
        let turns = ShepetalSummaryTests().turns(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { (speaker: $0.speaker, text: $0.text.trimmingCharacters(in: .whitespaces)) }
        let summary = try MeetingSummarizer().summarize(turns: turns)
        return .init(id: name, turns: turns.enumerated().map { .init(speaker: $1.speaker, start: Double($0 * 10), text: $1.text) },
                     summary: summary)
    }

    func ask(_ q: String, _ docs: MeetingAnswers.Doc...) -> MeetingAnswer { MeetingAnswers.answer(q, in: docs) }

    func testQuestionKinds() {
        let cases: [(String, MeetingAnswer.Kind)] = [
            ("Who will send the slides?", .actionItems), ("who's going to book the room", .actionItems),
            ("What are the action items?", .actionItems), ("what do I need to do", .actionItems),
            ("What does Kenji need to do?", .actionItems), ("next steps?", .actionItems),
            ("What did we decide about the release date?", .decisions), ("What was decided?", .decisions),
            ("what did we agree on", .decisions),
            ("When is the release?", .when), ("what's the deadline for the fix", .when),
            ("What did they say about the budget?", .said), ("What did Tom think about the crash?", .said),
            ("how did Grace feel about the sidebar", .said),
            ("drug names", .general), ("Who said the crash was scary?", .general), ("Summarize the discussion about pricing", .general),
        ]
        for (q, kind) in cases { XCTAssertEqual(MeetingAnswers.kind(of: q), kind, q) }
    }

    // "who will …" is answered from the summary's action items, with the owner and the due date as stored, and it
    // points at the line where it was said.
    func testWhoWillIsAnsweredFromTheActionItems() throws {
        let release = try fixture("01_release_planning")
        var a = ask("Who will run the regression suite?", release)
        XCTAssertEqual(a.kind, .actionItems)
        let first = try XCTUnwrap(a.quotes.first)
        XCTAssertEqual(first.source, .actionItem)
        XCTAssertEqual(first.speaker, "Priya")
        XCTAssertEqual(first.due, "Thursday")
        XCTAssertTrue(first.text.contains("run the regression suite"), first.text)
        let line = try XCTUnwrap(first.segment)
        XCTAssertEqual(release.turns[line].speaker, "Priya")
        XCTAssertTrue(release.turns[line].text.hasPrefix("Yes. I will run the regression suite on Thursday"), release.turns[line].text)
        XCTAssertEqual(first.start, Double(line * 10))

        a = ask("who is going to draft the release notes", release)
        XCTAssertEqual(a.quotes.first?.speaker, "Priya")
        XCTAssertEqual(a.quotes.first?.due, "Monday")

        let escalation = try fixture("02_customer_escalation")
        a = ask("Who will write the incident report?", escalation)
        XCTAssertEqual(a.quotes.map { [$0.speaker, $0.text, $0.due] }, [["Aisha", "write the incident report", "Monday"]])
    }

    func testActionItemListsFilterByOwner() throws {
        let release = try fixture("01_release_planning")
        let all = ask("What are the action items?", release)
        XCTAssertEqual(all.quotes.map(\.text), release.summary?.actionItems.map(\.task), "every item, in the summary's order")
        XCTAssertTrue(all.quotes.allSatisfy { $0.source == .actionItem })

        let escalation = try fixture("02_customer_escalation")
        let kenji = ask("What does Kenji need to do?", escalation)
        XCTAssertEqual(kenji.quotes.count, 3)
        XCTAssertEqual(Set(kenji.quotes.map(\.speaker)), ["Kenji"])
    }

    func testDecisionsComeFromTheSummary() throws {
        let release = try fixture("01_release_planning")
        let a = ask("What did we decide about the release date?", release)
        XCTAssertEqual(a.kind, .decisions)
        XCTAssertEqual(a.quotes.first?.source, .decision)
        XCTAssertEqual(a.quotes.first?.text, "We move the release from Monday the 3rd to Tuesday the 4th.")
        let line = try XCTUnwrap(a.quotes.first?.segment)
        XCTAssertTrue(release.turns[line].text.contains("we move the release from Monday the 3rd"), release.turns[line].text)

        let design = try fixture("03_design_review")
        XCTAssertEqual(ask("What was decided?", design).quotes.map(\.text), design.summary?.decisions)
    }

    // "what did X say about Y": only X's lines, ranked by Y.
    func testSaidAboutQuotesOnlyThatSpeaker() throws {
        let release = try fixture("01_release_planning")
        let tom = ask("What did Tom say about the crash?", release)
        XCTAssertEqual(tom.kind, .said)
        XCTAssertFalse(tom.quotes.isEmpty)
        XCTAssertEqual(Set(tom.quotes.map(\.speaker)), ["Tom"])
        XCTAssertTrue(tom.quotes.allSatisfy { $0.source == .transcript })
        XCTAssertTrue(release.turns[3].text.hasPrefix("So the crash happens on iPhone 11 and older"))
        XCTAssertTrue(tom.quotes.contains { $0.segment == 3 }, "\(tom.quotes.map(\.text))")

        // Maya says "release" most; asked about Tom, only his line comes back.
        let rel = ask("What did Tom say about releasing on Monday?", release)
        XCTAssertEqual(Set(rel.quotes.map(\.speaker)), ["Tom"])
        XCTAssertTrue(rel.quotes.first?.text.hasPrefix("I'd rather not release on a Monday morning") ?? false, "\(rel.quotes.map(\.text))")

        let priya = ask("what did Priya say about the store submission", release)
        XCTAssertEqual(priya.quotes.first?.speaker, "Priya")
        XCTAssertTrue(priya.quotes.first?.text.contains("Friday is enough for the store submission") ?? false, "\(priya.quotes.map(\.text))")
        XCTAssertEqual(ask("what did Tom say about the store submission", release).quotes, [], "Tom never said it")
    }

    func testGeneralQuestionsQuoteTheBestPassages() throws {
        let escalation = try fixture("02_customer_escalation")
        let a = ask("drug names", escalation)
        XCTAssertEqual(a.kind, .general)
        XCTAssertTrue((1...3).contains(a.quotes.count))
        XCTAssertEqual(a.quotes.first?.speaker, "Daniel")
        XCTAssertTrue(a.quotes.first?.text.contains("Drug names especially.") ?? false, "\(a.quotes.map(\.text))")

        let design = try fixture("03_design_review")
        let b = ask("What about voiceprints?", design)
        XCTAssertTrue(b.quotes.contains { $0.text.contains("voiceprints") }, "\(b.quotes.map(\.text))")
    }

    func testWhenPrefersLinesWithADate() throws {
        let release = try fixture("01_release_planning")
        let a = ask("When is the release?", release)
        XCTAssertEqual(a.kind, .when)
        XCTAssertTrue(a.quotes.contains { $0.text.contains("Tuesday the 4th") }, "\(a.quotes.map(\.text))")
    }

    // Nothing found is said plainly: an empty answer, never the nearest unrelated line.
    func testNothingFoundIsEmpty() throws {
        let release = try fixture("01_release_planning")
        XCTAssertEqual(ask("What did they say about the budget?", release).quotes, [])
        XCTAssertEqual(ask("Who will send the slides?", release).quotes, [], "\"send\" alone is not the slides")
        XCTAssertEqual(ask("kubernetes migration", release).quotes, [])
        XCTAssertEqual(ask("   ", release).quotes, [])
    }

    // The app's own meetings have two channels, Me and Others: "they" is Others and "I" is Me (M-MTG-1's call).
    func testMeAndOthersOnARecordedCall() throws {
        let segments = [
            Segment(speaker: .others, start: 2, end: 6, text: "Thanks for joining. Let's go through the launch."),
            Segment(speaker: .me, start: 7, end: 12, text: "Sure. The budget looks tight to me."),
            Segment(speaker: .others, start: 13, end: 20, text: "The budget is fine if we drop the paid ads."),
            Segment(speaker: .me, start: 21, end: 25, text: "I will send the slides by Friday."),
            Segment(speaker: .others, start: 26, end: 31, text: "I will review the budget tomorrow."),
        ]
        let record = MeetingRecord(meeting: Meeting(id: "zoom", app: "zoom.us", startedAt: Date(timeIntervalSince1970: 0),
                                                    endedAt: Date(timeIntervalSince1970: 60), meAudioPath: "", othersAudioPath: ""),
                                   segments: segments, summary: try MeetingSummarizer().summarize(segments))
        let slides = MeetingAnswers.answer("who will send the slides", in: [record])
        XCTAssertEqual(slides.quotes.first.map { [$0.speaker, $0.text, $0.due] }, ["Me", "send the slides", "Friday"])
        XCTAssertEqual(slides.quotes.first?.segment, 3)
        XCTAssertEqual(slides.quotes.first?.start, 21)

        let budget = MeetingAnswers.answer("What did they say about the budget?", in: [record])
        XCTAssertEqual(budget.kind, .said)
        XCTAssertEqual(Set(budget.quotes.map(\.speaker)), ["Others"])
        XCTAssertEqual(budget.quotes.first?.text, "The budget is fine if we drop the paid ads.")
        XCTAssertEqual(budget.quotes.first?.start, 13)
        let mine = MeetingAnswers.answer("what did I say about the budget", in: [record])
        XCTAssertEqual(mine.quotes.map(\.segment), [1])
        XCTAssertEqual(MeetingAnswers.answer("what do I need to do", in: [record]).quotes.map(\.text), ["send the slides"])
    }

    // Across meetings, each passage names the meeting it is from.
    func testAnswersAcrossMeetingsNameTheirMeeting() throws {
        let release = try fixture("01_release_planning"), design = try fixture("03_design_review")
        let a = ask("breakpoint at nine hundred points", release, design)
        XCTAssertEqual(a.quotes.first?.meetingID, "03_design_review")
        let b = ask("Who will open the pull request?", release, design)
        XCTAssertEqual(b.quotes.first?.meetingID, "01_release_planning")
        XCTAssertEqual(b.quotes.first?.speaker, "Tom")
        XCTAssertEqual(b.quotes.first?.source, .actionItem)
    }

    // A Russian call (F123's languages): words are matched across scripts' endings, question words are ignored.
    func testCyrillicMeetingsAreSearchedToo() {
        let doc = MeetingAnswers.Doc(id: "ru", turns: [
            .init(speaker: "Others", start: 0, text: "Добрый день, начнём с плана на квартал."),
            .init(speaker: "Me", start: 8, text: "Нам нужно утвердить размер бюджета до пятницы."),
            .init(speaker: "Others", start: 15, text: "Хорошо, я пришлю таблицу завтра."),
        ], summary: nil)
        let a = MeetingAnswers.answer("Что говорили про бюджет?", in: [doc])
        XCTAssertEqual(a.quotes.map(\.segment), [1])
    }

    func testSearchTermsAreTheContentWordsStemmed() {
        XCTAssertEqual(MeetingAnswers.searchTerms("What did they say about the budgets?"), ["budge"])
        XCTAssertEqual(MeetingAnswers.searchTerms("Who will send the slides?"), ["send", "slid"])
        XCTAssertTrue(MeetingAnswers.match("slid", "slide"))
        XCTAssertFalse(MeetingAnswers.match("ads", "adsorb"), "a stem under 4 letters must match whole")
    }

    // MARK: QMSum bench (docs/summarization.md)

    struct QMSumMeeting: Decodable {
        struct Turn: Decodable { let speaker: String; let content: String }
        struct Query: Decodable { let query: String; let relevant_text_span: [[String]] }
        let meeting_transcripts: [Turn]
        let specific_query_list: [Query]
    }

    /// Span recall on QMSum's specific queries: how often a quoted passage lies inside the turns the annotators
    /// marked as the answer's source (relevant_text_span). Runs only with SHEPETAL_QMSUM set to QMSum's data/ALL,
    /// fetched as summarize/eval_qmsum.py says; prints a Markdown table.
    func testQMSumSpanRecall() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHEPETAL_QMSUM"] else {
            throw XCTSkip("set SHEPETAL_QMSUM to QMSum's data/ALL (summarize/eval_qmsum.py fetches it)")
        }
        let fm = FileManager.default, root = URL(fileURLWithPath: dir)
        let files = try ["train", "val", "test"].flatMap { split in
            try fm.contentsOfDirectory(at: root.appendingPathComponent(split), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let summarizer = try MeetingSummarizer()
        let markup = try NSRegularExpression(pattern: "\\{[^}]*\\}"), spaced = try NSRegularExpression(pattern: "\\s+([.,?!])")
        func clean(_ s: String) -> String {  // as eval_qmsum.py's transcript(): no corpus markup, no spaced punctuation
            var t = markup.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
            t = spaced.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
            return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func domain(_ id: String) -> String {
            id.range(of: "^(ES|IS|TS)\\d", options: .regularExpression) != nil ? "AMI"
                : id.range(of: "^B[a-z]{2}\\d", options: .regularExpression) != nil ? "ICSI" : "Committee"
        }
        // per domain: queries, answered, hit@1, hit@3, chance@1, chance@3, seconds
        var rows: [String: [Double]] = [:], kinds: [String: [Double]] = [:]
        for file in files {
            let m = try JSONDecoder().decode(QMSumMeeting.self, from: Data(contentsOf: file))
            // Turn indices must stay those of the corpus, so empty turns stay, without text.
            let turns = m.meeting_transcripts.enumerated().map { MeetingAnswers.Turn(speaker: $1.speaker, start: Double($0), text: clean($1.content)) }
            let summary = summarizer.summarize(turns: turns.filter { !$0.text.isEmpty }.map { ($0.speaker, $0.text) })
            let doc = MeetingAnswers.Doc(id: file.lastPathComponent, turns: turns, summary: summary)
            let spoken = Double(turns.filter { !$0.text.isEmpty }.count)
            for q in m.specific_query_list {
                var relevant = Set<Int>()
                for span in q.relevant_text_span where span.count == 2 {
                    if let a = Int(span[0]), let b = Int(span[1]), a <= b { relevant.formUnion(a...b) }
                }
                guard !relevant.isEmpty else { continue }
                let t = Date()
                let a = MeetingAnswers.answer(q.query, in: [doc])
                let secs = Date().timeIntervalSince(t)
                let at = a.quotes.compactMap(\.segment)
                let c = Double(relevant.filter { $0 < turns.count && !turns[$0].text.isEmpty }.count) / max(1, spoken)
                let r: [Double] = [1, a.quotes.isEmpty ? 0 : 1, at.prefix(1).contains(where: relevant.contains) ? 1 : 0,
                                   at.prefix(3).contains(where: relevant.contains) ? 1 : 0, c, 1 - pow(1 - c, 3), secs]
                for key in [domain(file.lastPathComponent), "All"] {
                    rows[key] = zip(rows[key] ?? Array(repeating: 0, count: r.count), r).map(+)
                }
                kinds[a.kind.rawValue] = zip(kinds[a.kind.rawValue] ?? Array(repeating: 0, count: r.count), r).map(+)
            }
        }
        func pct(_ x: Double, _ n: Double) -> String { String(format: "%.1f%%", 100 * x / max(1, n)) }
        var out = ["| Corpus | Queries | Answered | Hit@1 | Hit@3 | Chance@1 | Chance@3 | Mean time |", "|---|---|---|---|---|---|---|---|"]
        for key in ["AMI", "ICSI", "Committee", "All"] {
            guard let r = rows[key] else { continue }
            out.append("| \(key) | \(Int(r[0])) | \(pct(r[1], r[0])) | \(pct(r[2], r[0])) | \(pct(r[3], r[0])) | \(pct(r[4], r[0])) | "
                       + "\(pct(r[5], r[0])) | \(String(format: "%.0f ms", 1000 * r[6] / r[0])) |")
        }
        out.append("")
        out.append("| Question kind | Queries | Answered | Hit@1 | Hit@3 |")
        out.append("|---|---|---|---|---|")
        for (k, r) in kinds.sorted(by: { $0.key < $1.key }) {
            out.append("| \(k) | \(Int(r[0])) | \(pct(r[1], r[0])) | \(pct(r[2], r[0])) | \(pct(r[3], r[0])) |")
        }
        print("QMSum span recall (\(files.count) meetings)\n" + out.joined(separator: "\n"))
        XCTAssertEqual(files.count, 232)
    }
}
