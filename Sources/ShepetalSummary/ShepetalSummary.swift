// Meeting summarizer: a port of summarize/summarize.py (approach textrank-tfidf). Not an LLM (rule 6).
// TF-IDF TextRank picks the overview and key points, keyword rules find decisions, and the logistic regression
// trained on AMI (summarize/ami_actions.py, weights in actions_model.json) plus rules finds action items.
// Tests/ShepetalSummaryTests holds it to the Python output; keep the two in step (summarize/export_golden.py).
import Foundation
import ShepetalCore

public struct MeetingSummarizer: MeetingSummarizing, Sendable {
    struct Model: Decodable, Sendable {
        let bias: Double
        let threshold: Double
        let weights: [String: Double]
    }

    let model: Model
    static let bundledModel = modelURL(inResources: Bundle.main.resourceURL)
        ?? Bundle.module.url(forResource: "actions_model", withExtension: "json")

    /// scripts/make-app.sh copies resource bundles into Contents/Resources, where Bundle.module does not look
    /// (it tries the .app root and the build dir, then crashes).
    static func modelURL(inResources dir: URL?) -> URL? {
        dir.flatMap { Bundle(url: $0.appendingPathComponent("Shepetal_ShepetalSummary.bundle")) }?
            .url(forResource: "actions_model", withExtension: "json")
    }

    /// Loads the action-item weights (the bundled ones by default). No fallback: a missing model throws.
    public init(modelURL: URL? = nil) throws {
        guard let url = modelURL ?? Self.bundledModel else {
            throw CocoaError(.fileNoSuchFile)
        }
        model = try JSONDecoder().decode(Model.self, from: Data(contentsOf: url))
    }

    init(model: Model) { self.model = model }

    /// Pure: no network, no I/O. Owners are the channel labels ("Me", "Others") or names said in the meeting.
    public func summarize(_ segments: [Segment]) -> Summary {
        summarize(turns: segments.map { ($0.speaker.rawValue, $0.text) })
    }

    /// Speaker turns in time order -> summary. The fixture tests feed named speakers through this.
    func summarize(turns: [(speaker: String, text: String)]) -> Summary {
        let sents = turns.flatMap { t in sentences(t.text).map { Sent(spk: t.speaker, text: $0) } }
        guard !sents.isEmpty else { return Summary(overview: "") }  // empty or silent recording
        let decs = decisions(sents)
        let acts = actionItems(sents)
        let texts = sents.map(\.text)
        let rank = textrank(texts)
        let used = Set(decs).union(acts.map { texts[$0.i] })
        let ok = texts.indices.filter { i in
            let s = texts[i]
            return words(s).count >= 8 && !s.hasSuffix("?") && !COMMIT.has(s) && !DECIDE.has(s) && !used.contains(s)
        }
        // ponytail: overview = best-ranked sentence in the opening (hosts state the purpose first).
        let overview = ok.prefix(5).max { rank[$0] < rank[$1] }.map { texts[$0] } ?? ""
        let byRank = ok.filter { texts[$0] != overview }.sorted { rank[$0] != rank[$1] ? rank[$0] > rank[$1] : $0 < $1 }
        let top = dedupe(byRank) { texts[$0] }.prefix(5).sorted()
        return Summary(overview: overview, keyPoints: top.map { texts[$0] }, decisions: decs,
                       actionItems: acts.map { ActionItem(owner: $0.who, task: $0.task, due: $0.due) })
    }

    // MARK: action items

    func actionItems(_ sents: [Sent]) -> [(i: Int, who: String, task: String, due: String)] {
        let p = actionScores(sents), al = aliases(sents)
        var out: [(i: Int, who: String, task: String, due: String)] = []
        for (i, s) in sents.enumerated() {
            let m = COMMIT.first(s.text)
            let asks = s.text.hasSuffix("?") && !REQUEST.has(FILLER.replace(s.text, ""))  // unless it asks someone to do it
            if asks || !(p[i] >= model.threshold || (m != nil && DUE.has(s.text))) { continue }
            let who = owner(sents, i, al)
            var task = (m != nil && who == s.spk ? group(m!, 1, s.text) : FILLER.replace(s.text, "")).strip(trailing: ".,")
            if words(task).isEmpty { continue }  // "Okay, so." scored high from its neighbours; there is no task to show
            // "follow up today and send it by Friday": the deadline is the "by" date
            let ds = DUE.all(task)
            let d = ds.first { m in
                let g = group(m, 0, task).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return g.hasPrefix("by ") || g.hasPrefix("before ")
            } ?? ds.first
            var due = ""
            if let d {
                due = group(d, 1, task)
                let t = task as NSString
                let rest = t.substring(to: d.range.location) + t.substring(from: NSMaxRange(d.range))
                task = SPACES.replace(rest) { $0.contains(",") ? "," : " " }.strip(both: " ,")
            }
            // The same task said twice by or to the same person: keep the later mention (the recap).
            out = out.filter { !($0.who == who && sameTask($0.task, task)) } + [(i, who, task, due)]
        }
        return out
    }

    /// P(sentence is an action item) = sigmoid(bias + the weights of its binary features), as in summarize.py.
    func actionScores(_ sents: [Sent]) -> [Double] {
        let n = sents.count
        let w = sents.map { words($0.text) }
        var counts: [String: Int] = [:]
        for s in sents { counts[s.spk, default: 0] += 1 }
        // The person who talks most runs the meeting (first speaker wins a tie, like Counter.most_common).
        var chair: String?
        for s in sents where chair == nil || counts[s.spk]! > counts[chair!]! { chair = s.spk }
        return sents.indices.map { i in
            let t = sents[i].text
            var f = Set(w[i].map { "u:" + $0 })
            f.formUnion(zip(w[i], w[i].dropFirst()).map { "b:\($0)_\($1)" })
            if i > 0 { f.formUnion(w[i - 1].map { "p:" + $0 }) }
            if i + 1 < n { f.formUnion(w[i + 1].map { "n:" + $0 }) }
            f.insert("pos\(10 * i / n)")
            f.insert("len\(min(5, w[i].count / 4))")
            for (k, on) in [("chair", sents[i].spk == chair), ("q", t.hasSuffix("?")), ("due", DUE.has(t)), ("commit", COMMIT.has(t))] where on {
                f.insert(k)
            }
            for (k, rx) in CUES where rx.has(t) { f.insert(k) }
            let z = model.bias + f.reduce(0) { $0 + (model.weights[$1] ?? 0) }
            return 1 / (1 + exp(-z))
        }
    }
}

struct Sent {
    let spk: String
    let text: String
}

// MARK: rules (same patterns as summarize.py)

let DAYS = "(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
let DUE = Re("\\b(?:by|on|before|for)?\\s*((?:next\\s+)?(?:\(DAYS)|week)(?:\\s+(?:morning|afternoon))?|today|tomorrow|tonight|end of (?:day|week)|the \\d+(?:st|nd|rd|th))\\b", .caseInsensitive)
let COMMIT = Re("\\bI(?:'ll| will)\\s+(.+)", .caseInsensitive)
let DECIDE = Re("\\b(decision|decided|is postponed|we (?:move|keep|use|ship|offer|skip|roll back|don't store)|let's (?:ship|not|skip|use))\\b", .caseInsensitive)
let SELF = Re("\\b(?:i'll|i will|i'm going to|i'm gonna|i can|let me|i have to|i need to|i should)\\b")
let YOU = Re("\\b(?:you|you'll|you're|your|you've|you'd)\\b")
let ME = Re("\\b(?:i|i'll|i'm|i've|i'd|me|my)\\b")
let DELEGATE = Re("\\s*(?:\\w+\\s+)?(?:ask|want|like|need|tell|get)\\b")
let INTRO = Re("\\b(?:I'm|I am|my name is|my name's|[Tt]his is)\\s+([A-Z][a-z]+)\\b(?!')")  // "This is Kate's laptop" is no intro
// "I'm the Industrial Designer", "I am your project lead": a job title said about oneself names the speaker like a label.
let TITLE = Re("\\b(?:I'm|I am)\\s+(?:(?:uh|um)\\s+)*(?:the|your|an?)\\s+((?:[A-Za-z]+\\s+){0,2}"
               + "(?:[Dd]esigner|[Mm]anager|[Ee]xpert|[Ee]ngineer|[Ll]ead|[Ss]pecialist|[Dd]eveloper|[Dd]irector|[Aa]nalyst))\\b")
let REQUEST = Re("^(?:(?:can|could|would|will) (?:you|someone|somebody)\\b|do you (?:want|wanna) to\\b)", .caseInsensitive)  // "Could you send it?"
let MODAL = "(?:will|'ll|should|could|can|must|(?:have|has|need|needs) to|(?:are|'re|is|am|'m) (?:going to|gonna)|gonna|might want to)"
/// Hand-off cues, one feature each ("you'll", "I'm going to", "so Kate will", "by next meeting").
let CUES = [("a:you", Re("\\byou(?: two| guys| both| all)?\\s*\(MODAL)", .caseInsensitive)),
            ("a:i", Re("\\bI\\s*\(MODAL)")),
            ("a:we", Re("\\bwe\\s*\(MODAL)", .caseInsensitive)),
            ("a:name", Re("(?<=\\s)[A-Z][a-z]{2,}(?: [A-Z][a-z]+)*\\s+\(MODAL)")),  // a capital that only opens the sentence is no name
            ("a:next", Re("\\b(?:next meeting|next time|for next|by next|before next|after lunch|after the break|meantime)\\b", .caseInsensitive))]
let FILLER = Re("^(?:(?:um|uh|so|and|okay|ok|well|yeah|right|but|then|also|now|alright)\\b[,.]?\\s*)+", .caseInsensitive)
let ONLY_DAY = Re("^\(DAYS)$", .caseInsensitive)
let DECISION_LEAD = Re("decision(?: made)?\\s*(?::|is)\\s*", .caseInsensitive)
let OPENER = Re("^(?:so|okay|yes|and)[, ]+", .caseInsensitive)
let SENTENCE_END = Re("(?<=[.!?])\\s+")
let SPACES = Re("\\s+,|\\s+")
let WORD = Re("[a-z0-9']+")
let TOKEN = Re("[A-Za-z0-9']+")

func sentences(_ body: String) -> [String] {
    SENTENCE_END.split(body.trimmingCharacters(in: .whitespacesAndNewlines))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

func words(_ s: String) -> [String] { WORD.findAll(s.lowercased()) }

/// words() with the case kept: names are matched as written.
func tokens(_ s: String) -> [String] { TOKEN.findAll(s) }

/// True when more than `t` of the shorter text's words are in the other one.
public func similar(_ a: String, _ b: String, _ t: Double = 0.5) -> Bool {
    let a = Set(words(a)), b = Set(words(b))
    return Double(a.intersection(b).count) / Double(max(1, min(a.count, b.count))) > t
}

let FUNCTION = Set("""
    i you we he she they it me my your our their his her them us i'll you'll we'll i'm you're we're they're it's
    that's i've you've we've i'd you'd will would shall should can could may might must have has had to be been being is are was
    were am do does did going gonna wanna got get a an the and or but so then on in at of for with by from about into up this that
    these those some any all um uh okay ok yeah yes well just like maybe also now right alright guys two both
    """.split(whereSeparator: \.isWhitespace).map(String.init))

/// similar() on content words: "you have to work on the components" and "you have to work on the interface" differ.
func sameTask(_ a: String, _ b: String) -> Bool {
    let ca = Set(words(a)).subtracting(FUNCTION), cb = Set(words(b)).subtracting(FUNCTION)
    guard !ca.isEmpty, !cb.isEmpty else { return similar(a, b) }
    return Double(ca.intersection(cb).count) / Double(min(ca.count, cb.count)) > 0.5
}

func dedupe<T>(_ items: [T], key: (T) -> String) -> [T] {
    var kept: [T] = []
    for it in items where !kept.contains(where: { similar(key(it), key($0)) }) { kept.append(it) }
    return kept
}

func dedupe(_ items: [String]) -> [String] { dedupe(items) { $0 } }

func decisions(_ sents: [Sent]) -> [String] {
    // ponytail: keyword rules tuned on English meeting phrasing; swap for a small classifier if recall is too low.
    var out: [String] = []
    for s in sents.map(\.text) where !s.hasSuffix("?") && words(s).count >= 6 && DECIDE.has(s) {
        let d = OPENER.replace(DECISION_LEAD.split(s).last!, "")
        if words(d).isEmpty { continue }  // "we reached our decision:" with the content in a later sentence
        out.append(d.prefix(1).uppercased() + d.dropFirst())
    }
    return dedupe(out)
}

/// {spoken phrase: speaker label}: each name of a speaker (the label and any job title they give themselves, "I'm the
/// Industrial Designer"), its words and its initials, plus first names people introduce themselves with.
/// owner() matches them as written: a name only when capitalized, initials only in capitals.
func aliases(_ sents: [Sent]) -> [String: String] {
    let labels = Set(sents.map(\.spk).filter { !$0.isEmpty }).sorted()
    var names = Dictionary(uniqueKeysWithValues: labels.map { ($0, [$0]) })
    for s in sents where !s.spk.isEmpty {
        for m in TITLE.all(s.text) {
            names[s.spk]!.append(group(m, 1, s.text).split(whereSeparator: \.isWhitespace)
                .filter { !["uh", "um"].contains($0.lowercased()) }.joined(separator: " "))
        }
    }
    var out: [String: String] = [:]
    let pairs = labels.flatMap { l in names[l]!.dropFirst().map { (l, $0) } } + labels.map { ($0, $0) }  // labels win over titles
    for (lab, name) in pairs {
        let toks = tokens(name).map { $0.prefix(1).uppercased() + $0.dropFirst() }  // "will" must not match "will"
        let others = Set(labels.filter { $0 != lab }.flatMap { names[$0]!.flatMap(words) })  // "Designer" names neither designer
        out[toks.joined(separator: " ")] = lab
        for w in toks where w.count >= 3 && !others.contains(w.lowercased()) && !w.allSatisfy(\.isNumber) { out[w] = lab }
        if toks.count > 1 { out[String(toks.map { $0.first! })] = lab }  // "Industrial Designer" is called "ID"
    }
    for s in sents where !s.spk.isEmpty {
        for m in INTRO.all(s.text) {
            let name = group(m, 1, s.text)
            if !ONLY_DAY.has(name) && out[name] == nil { out[name] = s.spk }  // "This is Friday" is a date, not a name
        }
    }
    return out
}

/// Who does it: a named participant, else "I" -> the speaker, "you" -> whoever answers, else the addressee.
func owner(_ sents: [Sent], _ i: Int, _ al: [String: String]) -> String {
    let spk = sents[i].spk
    let c = tokens(sents[i].text).joined(separator: " ")  // ASCII only, so w has the same offsets
    let w = c.lowercased()
    let named = al.compactMap { k, lab -> (Int, String)? in
        lab == spk ? nil : Re("\\b" + NSRegularExpression.escapedPattern(for: k) + "\\b").first(c).map { ($0.range.location, lab) }
    }.min { $0 < $1 }
    if let me = SELF.first(w),
       !(named.map { $0.0 < me.range.location || DELEGATE.first(w, anchoredAt: NSMaxRange(me.range)) != nil } ?? false) {
        return spk  // "I'll send the list to Daniel" is mine; "I'll ask Daniel to send it" is his
    }
    if let named { return named.1 }
    if YOU.has(w) || !ME.has(w) {
        // ponytail: addressee = the next other speaker, however long the hand-out runs (they usually acknowledge), else
        // the previous one within 3 sentences. Right about half the time on AMI: the rest is said with a look, not a word.
        for j in Array(i + 1 ..< sents.count) + Array(stride(from: i - 1, to: max(-1, i - 4), by: -1))
        where !sents[j].spk.isEmpty && sents[j].spk != spk {
            return sents[j].spk
        }
    }
    return spk
}

// MARK: TextRank over TF-IDF vectors

/// PageRank over the cosine-similarity graph of the sentences' TF-IDF vectors.
/// ponytail: dense n x n similarity, ~70 MB at 3,000 sentences (about 3 h of talk); go sparse if meetings get longer.
func textrank(_ texts: [String], iters: Int = 50, d: Double = 0.85) -> [Double] {
    let n = texts.count
    let docs = texts.map { words($0).reduce(into: [String: Double]()) { $0[$1, default: 0] += 1 } }
    let df = docs.reduce(into: [String: Double]()) { acc, c in for w in c.keys { acc[w, default: 0] += 1 } }
    let vecs = docs.map { c -> [String: Double] in
        let v = c.reduce(into: [String: Double]()) { $0[$1.key] = $1.value * log(Double(n) / df[$1.key]!) }
        let norm = v.values.reduce(0) { $0 + $1 * $1 }.squareRoot() + 1e-9
        return v.mapValues { $0 / norm }
    }
    var sim = [Double](repeating: 0, count: n * n)
    for i in 0..<n {
        for j in (i + 1)..<n {
            let (a, b) = vecs[i].count < vecs[j].count ? (vecs[i], vecs[j]) : (vecs[j], vecs[i])
            let dot = max(0, a.reduce(0) { $0 + $1.value * (b[$1.key] ?? 0) })
            sim[i * n + j] = dot
            sim[j * n + i] = dot
        }
    }
    for i in 0..<n {
        let s = sim[(i * n)..<(i * n + n)].reduce(0, +) + 1e-9
        for j in 0..<n { sim[i * n + j] /= s }
    }
    var r = [Double](repeating: 1 / Double(n), count: n)
    for _ in 0..<iters {
        var next = [Double](repeating: (1 - d) / Double(n), count: n)
        for i in 0..<n where r[i] != 0 {
            for j in 0..<n { next[j] += d * sim[i * n + j] * r[i] }
        }
        r = next
    }
    return r
}

// MARK: regex helpers (NSRegularExpression speaks the same dialect as Python's re for these patterns)

struct Re: @unchecked Sendable {  // NSRegularExpression is immutable and thread-safe
    let re: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func first(_ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// Python's pattern.match(s, pos): the match must start at pos.
    func first(_ s: String, anchoredAt pos: Int) -> NSTextCheckingResult? {
        re.firstMatch(in: s, options: .anchored, range: NSRange(location: pos, length: (s as NSString).length - pos))
    }

    func has(_ s: String) -> Bool { first(s) != nil }

    func all(_ s: String) -> [NSTextCheckingResult] {
        re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    func findAll(_ s: String) -> [String] { all(s).map { group($0, 0, s) } }

    func replace(_ s: String, _ with: (String) -> String) -> String {
        let ns = s as NSString
        var out = "", at = 0
        for m in all(s) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at)) + with(ns.substring(with: m.range))
            at = NSMaxRange(m.range)
        }
        return out + ns.substring(from: at)
    }

    func replace(_ s: String, _ with: String) -> String { replace(s) { _ in with } }

    /// Python's re.split for patterns without groups.
    func split(_ s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = [], at = 0
        for m in all(s) {
            out.append(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            at = NSMaxRange(m.range)
        }
        return out + [ns.substring(from: at)]
    }
}

func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
    let r = m.range(at: i)
    return r.location == NSNotFound ? "" : (s as NSString).substring(with: r)
}

extension String {
    /// Python's rstrip(chars).
    func strip(trailing chars: String) -> String {
        var s = Substring(self)
        while let c = s.last, chars.contains(c) { s = s.dropLast() }
        return String(s)
    }

    /// Python's strip(chars).
    func strip(both chars: String) -> String {
        var s = Substring(self)
        while let c = s.first, chars.contains(c) { s = s.dropFirst() }
        while let c = s.last, chars.contains(c) { s = s.dropLast() }
        return String(s)
    }
}

// MARK: notes (F71)

extension MeetingSummarizer {
    /// The summary with the user's notes merged in, without an LLM (rule 6), and apart from summarize(), which must
    /// keep saying what summarize.py says. A note line with an action cue ("TODO:", "[ ]", a deadline, "I'll", "we
    /// need to") goes through the action-item extractor as said by "Me", and those items come first; a key point
    /// that a note already says is dropped. The notes themselves are shown first, as "Your notes", by whoever
    /// renders the summary. No notes: the summary unchanged.
    public func merge(_ summary: Summary, notes: String) -> Summary {
        let lines = noteLines(notes)
        guard !lines.isEmpty else { return summary }
        let cued = lines.compactMap { l -> String? in
            if TODO.has(l) { return TODO.replace(l, "") }
            return COMMIT.has(l) || DUE.has(l) || CUES.contains(where: { $0.1.has(l) }) ? l : nil
        }
        // The cue picks the lines, not the score: the weights were trained on speech and rate a typed
        // "Send the deck by Friday" far below the threshold.
        let typed = MeetingSummarizer(model: Model(bias: model.bias, threshold: 0, weights: model.weights))
        let me = Speaker.me.rawValue
        let mine = typed.actionItems(cued.map { Sent(spk: me, text: $0) }).map { ActionItem(owner: me, task: $0.task, due: $0.due) }
        var s = summary
        // ponytail: a note of three words or fewer repeats no key point; similar() alone would drop every key point
        // that shares the one word of a note like "budget".
        s.keyPoints.removeAll { k in lines.contains { words($0).count > 3 && similar(k, $0) } }
        s.actionItems = mine + s.actionItems.filter { a in !mine.contains { $0.owner == a.owner && sameTask($0.task, a.task) } }
        return s
    }
}

/// The lines of the notes as shown under "Your notes": blank lines and list markers ("- ", "* ", "• ", "1. ") dropped.
public func noteLines(_ notes: String) -> [String] {
    notes.components(separatedBy: .newlines)
        .map { NOTE_MARKER.replace($0, "").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

let NOTE_MARKER = Re("^\\s*(?:[-*•]|\\d+[.)])\\s+")
let TODO = Re("^(?:\\[ ?\\]|todo\\b:?|to-?do:|action(?: item)?:)\\s*", .caseInsensitive)
