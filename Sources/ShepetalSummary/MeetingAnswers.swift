// Ask about meetings (F73) without an LLM (rule 6): rules sort the question into a kind, and the answer is quoted,
// never written. Action-item and decision questions are answered from the stored summary; the rest by ranking the
// transcript's sentences (BM25 over word stems, with the neighbouring sentences as context). Each answer points at
// where it was said, so the UI can open the transcript there. Pure: no network, no I/O.
import Foundation
import ShepetalCore

public struct MeetingAnswer: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// "who will send the slides", "what are the action items", "what do I need to do"
        case actionItems
        /// "what did we decide about the release"
        case decisions
        /// "when is the release"
        case when
        /// "what did they say about the budget": the transcript, only what that speaker said
        case said
        /// anything else: the transcript
        case general
    }

    public struct Quote: Equatable, Sendable {
        public enum Source: String, Sendable { case transcript, actionItem, decision, keyPoint }
        public var meetingID: String
        public var source: Source
        /// Who said it; for an action item, its owner as the summary has it ("" when nobody took it).
        public var speaker: String
        /// The transcript as said, or the summary item as stored.
        public var text: String
        /// An action item's due date as said; "" otherwise.
        public var due: String
        /// Index into the meeting's segments where it was said; nil when a summary item matches no line.
        public var segment: Int?
        /// Seconds into the meeting, the segment's start.
        public var start: Double?

        public init(meetingID: String, source: Source, speaker: String, text: String, due: String = "",
                    segment: Int? = nil, start: Double? = nil) {
            self.meetingID = meetingID
            self.source = source
            self.speaker = speaker
            self.text = text
            self.due = due
            self.segment = segment
            self.start = start
        }
    }

    public var kind: Kind
    /// Best first. Empty: nothing in the meetings answers the question, which the UI says plainly.
    public var quotes: [Quote]
}

public enum MeetingAnswers {
    /// Transcript answers: at most this many passages, each at least `keep` of the best one's score.
    static let passages = 3, keep = 0.4
    /// Summary answers list at most this many items.
    static let items = 10

    /// The meetings in `records` (already shortlisted by the caller) answer `question`.
    public static func answer(_ question: String, in records: [MeetingRecord]) -> MeetingAnswer {
        answer(question, in: records.map { r in
            Doc(id: r.meeting.id, turns: r.segments.map { Turn(speaker: $0.speaker.rawValue, start: $0.start, text: $0.text) },
                summary: r.summary)
        })
    }

    /// The words the store's search index should shortlist meetings by: the question's content words, stemmed.
    public static func searchTerms(_ question: String) -> [String] {
        parse(question, speakers: []).terms
    }

    // MARK: the question

    struct Doc {
        let id: String
        let turns: [Turn]
        let summary: Summary?
    }

    struct Turn {
        let speaker: String
        let start: Double
        let text: String
    }

    struct Question {
        var kind: MeetingAnswer.Kind
        /// Content words, stemmed.
        var terms: [String]
        /// The speaker label the question is about ("what did they say", "what do I need to do"); nil for anyone.
        var who: String?
    }

    static func kind(of question: String) -> MeetingAnswer.Kind { parse(question, speakers: []).kind }

    /// `speakers` are the labels in the meetings ("Me", "Others", or names) and `owners` the action items' owners:
    /// a question naming one of them is about them.
    static func parse(_ question: String, speakers: [String], owners: [String] = []) -> Question {
        let q = question.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        var kind = MeetingAnswer.Kind.general
        var subject: String?
        if let m = SAID.first(q) {
            kind = .said
            subject = group(m, 1, q)
        } else if let m = WHO_DOES.first(q) {
            kind = .actionItems
            subject = group(m, 1, q)  // "what does Tom need to do": Tom; "who will …" names nobody
        } else if ACTIONS.has(q) {
            kind = .actionItems
        } else if DECIDED.has(q) {
            kind = .decisions
        } else if WHEN.has(q) {
            kind = .when
        }
        var who: String?
        if kind == .said || kind == .actionItems {
            // A name said in the question; "Me" and "Others" are never said as names, only as pronouns below.
            let channels = Set(Speaker.allCases.map(\.rawValue))
            let names = Set(speakers + (kind == .actionItems ? owners : [])).subtracting(channels).filter { !$0.isEmpty }
            who = names.sorted { $0.count > $1.count }  // "Project Manager" before "Manager"
                .first { n in Re("\\b" + NSRegularExpression.escapedPattern(for: n.lowercased()) + "\\b").has(q) }
            let mine = Re("\\b(?:i|me|my|i'm|i'll)\\b")
            if who == nil, let s = subject {
                if mine.has(s) { who = Speaker.me.rawValue }
                else if Re("\\b(?:they|them|their|others|the other side|he|she)\\b").has(s) { who = Speaker.others.rawValue }
            } else if who == nil, kind == .actionItems, !q.hasPrefix("who"), mine.has(q) {
                who = Speaker.me.rawValue  // "what are my action items"
            }
            if let w = who, channels.contains(w), !speakers.isEmpty, !speakers.contains(w) { who = nil }  // no such channel
        }
        var named = Set(who.map { terms($0) } ?? [])
        if let s = subject { named.formUnion(terms(s)) }  // "what did the PhD F say": not about "phd"
        let ts = terms(q).filter { !named.contains($0) && !CUE.contains($0) }
        return Question(kind: kind, terms: unique(ts.map(stem)), who: who)
    }

    // MARK: answering

    static func answer(_ question: String, in docs: [Doc]) -> MeetingAnswer {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return MeetingAnswer(kind: .general, quotes: []) }
        let index = Index(docs)
        let q = parse(question, speakers: Array(Set(docs.flatMap { $0.turns.map(\.speaker) })),
                      owners: docs.flatMap { $0.summary?.actionItems.map(\.owner) ?? [] })
        switch q.kind {
        case .actionItems:
            let found = actionItems(q, docs, index)
            return MeetingAnswer(kind: q.kind, quotes: found.isEmpty ? passages(q, index) : found)
        case .decisions:
            let found = decisions(q, docs, index)
            return MeetingAnswer(kind: q.kind, quotes: found.isEmpty ? passages(q, index) : found)
        case .general where q.terms.isEmpty:
            return MeetingAnswer(kind: q.kind, quotes: keyPoints(docs, index))  // "what was it about?"
        case .when, .said, .general:
            return MeetingAnswer(kind: q.kind, quotes: passages(q, index))
        }
    }

    /// The summaries' action items whose owner and task fit the question, as stored, pointing at the line they came from.
    static func actionItems(_ q: Question, _ docs: [Doc], _ index: Index) -> [MeetingAnswer.Quote] {
        var out: [(Double, MeetingAnswer.Quote)] = []
        for d in docs {
            for a in d.summary?.actionItems ?? [] where q.who == nil || a.owner.caseInsensitiveCompare(q.who!) == .orderedSame {
                // The task with the lines it came from: "open it" was "the pull request" one sentence earlier.
                let at = index.place(a.task, in: d.id, by: a.owner)
                // Most of the question must be in it: "send the invoice" is not "send the slides".
                guard let fit = index.fit(q.terms, stems([a.task, a.due, at.map(index.context) ?? ""].joined(separator: " ")), share: 0.5)
                else { continue }
                let turn = at.map { index.sents[$0].turn }
                out.append((fit, .init(meetingID: d.id, source: .actionItem, speaker: a.owner, text: a.task, due: a.due,
                                       segment: turn, start: turn.map { d.turns[$0].start })))
            }
        }
        return Array(out.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
            .map(\.element.1).prefix(items))
    }

    static func decisions(_ q: Question, _ docs: [Doc], _ index: Index) -> [MeetingAnswer.Quote] {
        var out: [(Double, MeetingAnswer.Quote)] = []
        for d in docs {
            for text in d.summary?.decisions ?? [] {
                // Any word of the question will do: decisions are few, and "the release date" is "the release" there.
                guard let fit = index.fit(q.terms, stems(text), share: 0) else { continue }
                let turn = index.place(text, in: d.id).map { index.sents[$0].turn }
                out.append((fit, .init(meetingID: d.id, source: .decision, speaker: turn.map { d.turns[$0].speaker } ?? "",
                                       text: text, segment: turn, start: turn.map { d.turns[$0].start })))
            }
        }
        return Array(out.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
            .map(\.element.1).prefix(items))
    }

    /// A question with nothing to look for: the summaries' overview and key points, each a sentence from the transcript.
    static func keyPoints(_ docs: [Doc], _ index: Index) -> [MeetingAnswer.Quote] {
        let found = docs.flatMap { d in
            ((d.summary.map { [$0.overview] + $0.keyPoints } ?? []).filter { !$0.isEmpty }).map { text in
                let turn = index.place(text, in: d.id).map { index.sents[$0].turn }
                return MeetingAnswer.Quote(meetingID: d.id, source: .keyPoint, speaker: turn.map { d.turns[$0].speaker } ?? "",
                                           text: text, segment: turn, start: turn.map { d.turns[$0].start })
            }
        }
        return Array(found.prefix(items))
    }

    /// The best 1 to 3 passages of the transcript, one per segment, quoted with who said them and when.
    static func passages(_ q: Question, _ index: Index) -> [MeetingAnswer.Quote] {
        guard !q.terms.isEmpty else { return [] }
        let total = q.terms.reduce(0) { $0 + index.idf($1) }
        var scored: [(score: Double, i: Int)] = []
        for (i, s) in index.sents.enumerated() where q.who == nil || s.speaker == q.who {
            let own = index.bm25(q.terms, i)
            guard own > 0 else { continue }  // the sentence itself must say something asked about
            // Its neighbours in the same meeting count as context, at a third.
            let near = [i - 1, i + 1].filter { $0 >= 0 && $0 < index.sents.count && index.sents[$0].doc == s.doc }
            let covered = Set(q.terms.filter { t in ([i] + near).contains { index.sents[$0].stems.contains { match($0, t) } } })
            // Most of what was asked must be there: "send the slides" is not answered by "send the invoice".
            guard covered.reduce(0, { $0 + index.idf($1) }) >= 0.5 * total else { continue }
            var score = own + near.map { index.bm25(q.terms, $0) }.reduce(0, +) / 3
            if q.kind == .when && TIME.has(s.text) { score *= 2 }
            scored.append((score, i))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.i < $1.i }
        var out: [MeetingAnswer.Quote] = [], seen = Set<String>()
        for (score, i) in scored where score >= keep * (scored.first?.score ?? 0) {
            let s = index.sents[i]
            guard seen.insert("\(s.doc)/\(s.turn)").inserted else { continue }
            let turn = index.docs[s.doc].turns[s.turn]
            out.append(.init(meetingID: index.docs[s.doc].id, source: .transcript, speaker: turn.speaker,
                             text: index.passage(i), segment: s.turn, start: turn.start))
            if out.count == passages { break }
        }
        return out
    }

    // MARK: the transcript index

    struct Sent {
        let doc: Int
        let turn: Int
        let text: String
        let speaker: String
        let stems: [String]
    }

    /// Every sentence of the meetings, with its stems and document frequencies for BM25.
    final class Index {
        let docs: [Doc]
        let sents: [Sent]
        let avg: Double
        private let df: [String: Int]
        private var idfs: [String: Double] = [:]

        init(_ docs: [Doc]) {
            self.docs = docs
            var sents: [Sent] = []
            for (d, doc) in docs.enumerated() {
                for (t, turn) in doc.turns.enumerated() {
                    for s in sentences(turn.text) { sents.append(Sent(doc: d, turn: t, text: s, speaker: turn.speaker, stems: stems(s))) }
                }
            }
            self.sents = sents
            avg = Double(sents.reduce(0) { $0 + $1.stems.count }) / Double(max(1, sents.count))
            var df: [String: Int] = [:]
            for s in sents { for w in Set(s.stems) { df[w, default: 0] += 1 } }
            self.df = df
        }

        /// Rarer words weigh more. A word said nowhere weighs most, so a question about it finds nothing.
        func idf(_ term: String) -> Double {
            if let w = idfs[term] { return w }
            // ponytail: an upper bound when several stems match (a sentence can hold two of them); fine for ranking.
            let n = min(sents.count, df.reduce(0) { $0 + (match($1.key, term) ? $1.value : 0) })
            let w = log(1 + (Double(sents.count) - Double(n) + 0.5) / (Double(n) + 0.5))
            idfs[term] = w
            return w
        }

        func bm25(_ terms: [String], _ i: Int) -> Double {
            let w = sents[i].stems, k1 = 1.2, b = 0.75
            return terms.reduce(0) { sum, t in
                let tf = Double(w.filter { match($0, t) }.count)
                return tf == 0 ? sum : sum + idf(t) * tf * (k1 + 1) / (tf + k1 * (1 - b + b * Double(w.count) / max(1, avg)))
            }
        }

        /// How well a summary item fits the question, or nil when it does not: no terms fit everything. `share` is
        /// how much of the question (by weight) the item must say.
        func fit(_ terms: [String], _ item: [String], share: Double) -> Double? {
            guard !terms.isEmpty else { return 0 }
            let total = terms.reduce(0) { $0 + idf($1) }
            let got = terms.filter { t in item.contains { match($0, t) } }.reduce(0) { $0 + idf($1) }
            return got > 0 && got >= share * total ? got : nil
        }

        /// The sentence (an index into `sents`) a summary item was taken from: the last one that says it word for word (the summarizer keeps
        /// the later mention, the recap), preferring `by` (the owner), else the one with most of its words.
        func place(_ item: String, in id: String, by owner: String = "") -> Int? {
            guard let d = docs.firstIndex(where: { $0.id == id }) else { return nil }
            let mine = sents.indices.filter { sents[$0].doc == d }
            let said = item.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
            let exact = said.isEmpty ? [] : mine.filter { sents[$0].text.range(of: said, options: .caseInsensitive) != nil }
            if let i = exact.last(where: { sents[$0].speaker == owner }) ?? exact.last { return i }
            let want = Set(stems(item))
            guard !want.isEmpty else { return nil }
            var best: (score: Int, i: Int)?
            for i in mine {
                let got = want.filter { w in sents[i].stems.contains { match($0, w) } }.count
                if got > (best?.score ?? 0) { best = (got, i) }
            }
            guard let best, Double(best.score) >= 0.6 * Double(want.count) else { return nil }
            return best.i
        }

        /// The sentence and the one before it in the same meeting: "Tom, you will open the pull request." "I will open it."
        func context(_ i: Int) -> String {
            i > 0 && sents[i - 1].doc == sents[i].doc ? sents[i - 1].text + " " + sents[i].text : sents[i].text
        }

        /// What is quoted: the whole segment when it is short, else the sentence with one on each side from that segment.
        func passage(_ i: Int) -> String {
            let s = sents[i], turn = docs[s.doc].turns[s.turn]
            if UWORD.findAll(turn.text).count <= 40 { return turn.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            let same = [i - 1, i, i + 1].filter { $0 >= 0 && $0 < sents.count && sents[$0].doc == s.doc && sents[$0].turn == s.turn }
            return same.map { sents[$0].text }.joined(separator: " ")
        }
    }

    // MARK: words

    /// Lowercased words in any script ("бюджет", "slides", "2.4" as "2" and "4"), with the stop words left out.
    static func terms(_ s: String) -> [String] {
        UWORD.findAll(s.lowercased().replacingOccurrences(of: "’", with: "'"))
            .map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 }
            .filter { !STOP.contains($0) && !$0.isEmpty }
    }

    static func stems(_ s: String) -> [String] { terms(s).map(stem) }

    /// A crude stem that keeps the start of the word: "slides" and "slide" → "slid", "budgets" → "budge".
    /// match() then lets one stem be the start of the other, which also covers many Cyrillic endings.
    static func stem(_ w: String) -> String {
        let n = w.count
        return n >= 6 ? String(w.prefix(n - 2)) : n == 5 ? String(w.prefix(4)) : w
    }

    static func match(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        return short.count >= 4 && long.hasPrefix(short)
    }

    static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0).inserted }
    }
}

// MARK: rules

/// "what did they say about", "what did the Project Manager think of", "how did Kate feel about"
private let SAID = Re("\\b(?:what|how|why)\\s+(?:did|does|do|has|have|was|were|is|are|will|would)\\s+(.+?)\\s+"
                      + "(?:say|said|saying|think|thought|mention|mentioned|suggest|suggested|propose|proposed|feel|felt|tell|told|"
                      + "talk|talked|ask|asked|explain|explained|report|reported|present|presented|recommend|recommended|argue|argued)\\b")
/// "who will send the slides", "who is going to", "what does Tom need to do", "what should I do"
private let WHO_DOES = Re("^(?:so\\s+|and\\s+)?who(?:\\s+will|'ll|(?:\\s+is|'s)\\s+(?:going\\s+to|gonna|doing|responsible|in\\s+charge)|\\s+should|"
                          + "\\s+has\\s+to|\\s+needs\\s+to|\\s+must|\\s+takes|\\s+owns|\\s+does|\\s+can)\\b|"
                          + "\\bwhat\\s+(?:do|does|did|should|must|will)\\s+(.+?)\\s+(?:need\\s+to\\s+|have\\s+to\\s+|has\\s+to\\s+|supposed\\s+to\\s+)?do\\b")
private let ACTIONS = Re("\\b(action items?|to-?dos?|next steps?|follow[- ]ups?|tasks?|assignments?|assigned|homework|(my|your|his|her|their|our) jobs?)\\b")
private let DECIDED = Re("\\b(?:decide|decided|deciding|decision|decisions|agree|agreed|agreement|conclude|concluded|conclusion|settle|settled|outcome)\\b")
private let WHEN = Re("^\\s*when\\b|\\bwhat\\s+(?:day|date|time)\\b|\\b(?:deadline|due|how\\s+long|by\\s+when)\\b")
/// A day, date or time said in a sentence.
private let TIME = Re("\\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|today|tomorrow|tonight|yesterday|"
                      + "week|month|year|morning|afternoon|evening|january|february|march|april|may|june|july|august|september|"
                      + "october|november|december|o'clock|noon|midnight|\\d{1,2}(?::\\d\\d)?\\s*(?:am|pm|a\\.m\\.|p\\.m\\.)|"
                      + "\\d{1,2}(?:st|nd|rd|th)|q[1-4]|\\d{1,2}[./]\\d{1,2}(?:[./]\\d{2,4})?)\\b", .caseInsensitive)
private let UWORD = Re("[\\p{L}\\p{M}][\\p{L}\\p{M}\\p{N}']*|\\p{N}+")

/// Words that ask, not what is asked about.
private let CUE = Set("""
    say said saying think thought mention mentioned suggest suggested propose proposed feel felt tell told talk talked
    ask asked explain explained report reported present presented recommend recommended argue argued discuss discussed
    discussion discussing summarize summarise summary decide decided deciding decision decisions agree agreed agreement
    conclude concluded conclusion settle settled outcome action item items todo todos to-do to-dos next step steps
    follow follow-up follow-ups task tasks assignment assignments assigned homework job jobs need needs supposed meeting
    meetings call group team happen happened opinion opinions view views idea ideas when deadline due long whole
    """.split(whereSeparator: \.isWhitespace).map(String.init))

/// English function and question words.
private let STOP = FUNCTION.union("""
    what what's whats who who's whom whose which where why how is was are were the a an about of on for regarding
    anything something everything there their they them he she his her him its it's not no did does do done doing
    than as if else each other others more most such only own same too very s t don't didn't isn't wasn't aren't
    any many much there's here let's let us ok okay hmm mm
    """.split(whereSeparator: \.isWhitespace).map(String.init)).union(RU_UK)

/// Question and function words of Russian and Ukrainian, which the meeting speech model transcribes (F123's meetings).
private let RU_UK = Set("""
    что кто как когда где почему зачем какой какая какие о об про в во на и а но по за к с со у из от до мы вы они он
    она оно я мне меня нас вас их его её ее это этот эта эти тот там тут был была были было есть ли же не ни бы
    сказал сказала сказали говорил говорила говорили решили решение будет будут
    що хто як коли де чому який яка які про в у на і й та але по за до з із від ми ви вони він вона воно я мені мене
    нас вас їх його її це цей ця ці той там тут був була були було є чи ж не ні б сказав сказала сказали говорив
    говорила говорили вирішили рішення буде будуть
    """.split(whereSeparator: \.isWhitespace).map(String.init))
