import CryptoKit
import Foundation

/// A local text model that rewrites dictation (goal rule 5): self-corrections, spoken lists, punctuation and
/// spoken line breaks. `ShepetalCleanup.LlamaCleanup` is the real one (llama.cpp); tests use a fake.
/// One call at a time.
public protocol CleanupModel: AnyObject, Sendable {
    var name: String { get }
    /// Text that already went through `Cleanup.apply` in, rewritten text out.
    func rewrite(_ text: String) throws -> String
    /// The same, with the text around the cursor for reference (F24). A model that cannot use it gets the
    /// default, which ignores it.
    func rewrite(_ text: String, context: CleanupContext) throws -> String
    /// The same, written in the user's voice (F38). A model that cannot use it gets the default, which ignores it.
    func rewrite(_ text: String, context: CleanupContext, voice: MyVoice) throws -> String
}

extension CleanupModel {
    public func rewrite(_ text: String, context: CleanupContext) throws -> String { try rewrite(text) }
    public func rewrite(_ text: String, context: CleanupContext, voice: MyVoice) throws -> String { try rewrite(text, context: context) }
}

/// The text around the cursor that the model may look at, when Settings' "Use the text around the cursor to clean
/// up dictation" is on (F24, on by default since Pavel's call of 2026-10-21; Wispr's `useAxContext`): the last 500
/// characters before the cursor, the first 500 after it and the selection, each cut at a word boundary. Reference
/// only: the word guard still rejects any word the user did not say. Never logged or stored, so `description` gives
/// only the lengths.
public struct CleanupContext: Equatable, Sendable, CustomStringConvertible {
    public static let settingKey = "cleanup.textAroundCursor"
    public static let limit = 500
    public static let none = CleanupContext(before: "", after: "", selected: "")
    /// The setting, on unless the user switched it off.
    public static func isOn(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: settingKey) as? Bool ?? true }

    public let before: String
    public let after: String
    public let selected: String

    public init(before: String, after: String, selected: String) {
        self.before = Self.last(before)
        self.after = Self.first(after)
        self.selected = Self.first(selected)
    }

    public var isEmpty: Bool { before.isEmpty && after.isEmpty && selected.isEmpty }
    public var description: String { "CleanupContext(\(before.count) + \(selected.count) + \(after.count) characters)" }

    /// The number of the list item on the line above the cursor, when the cursor starts a new line after it
    /// ("1. Milk\n2. Eggs\n"): the model's "3. Bread" goes on with that list. 0 otherwise. Any line break counts:
    /// Word's fields end paragraphs with "\r".
    public var listNumber: Int {
        let lines = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > 1, lines[lines.count - 1].allSatisfy(\.isWhitespace) else { return 0 }
        let line = String(lines[lines.count - 2]) as NSString
        guard let m = SmartCleanup.listNumber.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else { return 0 }
        return Int(line.substring(with: m.range).filter(\.isNumber)) ?? 0
    }

    /// The last `limit` characters, from the first word that starts inside them.
    static func last(_ s: String) -> String {
        guard s.count > limit else { return s }
        let cut = s.suffix(limit)
        if s[s.index(before: cut.startIndex)].isWhitespace { return String(cut) }
        return cut.firstIndex(where: \.isWhitespace).map { String(cut[$0...]) } ?? ""
    }

    /// The first `limit` characters, up to the last word that ends inside them.
    static func first(_ s: String) -> String {
        guard s.count > limit else { return s }
        let cut = s.prefix(limit)
        if s[cut.endIndex].isWhitespace { return String(cut) }
        return cut.lastIndex(where: \.isWhitespace).map { String(cut[..<$0]) } ?? ""
    }
}

/// The rules first (fillers, stutters, spacing), then the model when one is loaded and the text has a cue
/// for it. The rules' text is what the user gets whenever the model is missing, fails, or writes words the
/// user did not say (a small model will happily answer "What is the capital of Australia?").
public enum SmartCleanup {
    public struct Result: Equatable {
        public let text: String
        public let usedModel: Bool
    }

    /// Longer dictations get the rules only: decode time grows with the text, and the instructions plus a long
    /// text would overrun the model's context.
    public static let maxModelWords = 150

    /// `context` is the text around the cursor (F24); `.none` unless the user turned it on. `voice` is My voice
    /// (F38): with one, every dictation goes to the model, since any of them may need the user's voice, and the
    /// guard lets contractions change.
    public static func apply(_ raw: String, model: CleanupModel?, context: CleanupContext = .none,
                             voice: MyVoice = .none) -> Result {
        let ruled = Cleanup.apply(raw), list = context.listNumber, voiced = !voice.isEmpty
        guard let model, (voiced && !ruled.isEmpty) || needsModel(ruled) || (list > 0 && has(nextItem, ruled)),
              words(ruled).count <= maxModelWords, let out = try? model.rewrite(ruled, context: context, voice: voice),
              accepts(out, for: ruled, list: list, contractions: voiced) else {
            return Result(text: ruled, usedModel: false)
        }
        return Result(text: out, usedModel: true)
    }

    /// "I mean it" is emphasis, not a cue; "I mean it's Wednesday" is one.
    static let corrections = try! NSRegularExpression(pattern: #"""
        (?xi) (?:,\ )? \b(?: actually,?\ no | actually | i\ mean(?!\ it\b(?!['’])) | no,?\ wait | wait,?\ no | scratch\ that | strike\ that
          | cancel\ that | forget\ that | never\ mind | or\ rather | make\ that | sorry | correction | let\ me\ rephrase )\b
        | ,\ no\b
        """#)
    static let layout = try! NSRegularExpression(pattern: #"""
        (?xi) \b(?: first | second | third | finally | number\ (?:one|two|1|2) | step\ (?:one|two|1|2) | bullet\ point
          | new\ line | new\ paragraph )\b
        | \bone,.*\btwo,
        """#)
    /// Spoken list and line-break markers. They count as layout only at the start of an item (see `listMarkers`).
    static let listMarker = try! NSRegularExpression(pattern: #"""
        (?xi) \b(?: (?:number|step)\ (?:one|two|three|four|five|six|seven|eight|nine|ten|\d+) | bullet\ point
          | new\ line | new\ paragraph | first | second | third | fourth | fifth | finally
          | one | two | three | four | five | six | seven | eight | nine | ten )\b
        """#)
    /// "Number three, ..." opening a dictation under a list (F24): a cue only with that list above the cursor.
    static let nextItem = try! NSRegularExpression(pattern: #"(?i)^(?:and\ )?(?:number|step)\ (?:three|four|five|six|seven|eight|nine|ten|\d+)\b"#)
    /// "1. " or "2) " at the start of a line: the model's list numbers.
    static let listNumber = try! NSRegularExpression(pattern: #"(?m)^\s*\d+[.)]\s"#)

    /// Self-correction, list and line-break cues, or no sentence punctuation at all.
    /// ponytail: cue words only; a correction said without one ("Tuesday, Wednesday") stays as heard.
    public static func needsModel(_ text: String) -> Bool {
        if text.isEmpty { return false }
        if !text.contains(where: { ".?!".contains($0) }) { return true }
        return has(corrections, text) || has(layout, text)
    }

    /// The model's text is used only when it is the user's own words, in the user's order, with nothing added
    /// and only these words left out:
    /// - list and line-break words ("first", "number two", "new line") when the text has a list or line-break cue;
    /// - a self-correction: the whole cue ("I mean", "scratch that") together with at least one word of what it
    ///   takes back, from the words just before it in the same sentence (at most 8), or the sentence before when
    ///   the cue opens a sentence (at most 20), and no more words than replace them, plus one.
    /// Only list numbers at the start of a line may be added; punctuation, case and line breaks may change.
    /// So a rewrite that keeps the taken-back words ("Send it to John"), swaps the halves, drops a cue but keeps
    /// what it took back, answers a question, or drops a clause elsewhere is rejected and the rules' text is used.
    /// `list` is the list number on the line above the cursor (`CleanupContext.listNumber`): numbering may go on from it.
    /// With `contractions` (My voice, F38), both texts are compared with their contractions spelled out, so "do not"
    /// may become "don't" and back.
    public static func accepts(_ out: String, for input: String, list: Int = 0, contractions: Bool = false) -> Bool {
        if contractions { return accepts(MyVoice.spellOut(out), for: MyVoice.spellOut(input), list: list) }
        guard out.contains(where: \.isLetter) else { return false }
        let said = tokens(input)
        let written = tokens(replace(listNumber, in: out)).map(\.word)
        let n = said.count, ns = input as NSString
        guard n > 0, !written.isEmpty else { return false }

        // A sentence starts after ". " (or ! ?) before a capital, so "3 p.m., no" is one sentence.
        let opens = said.indices.map { k -> Bool in
            guard k > 0 else { return true }
            let gap = ns.substring(with: NSRange(location: NSMaxRange(said[k - 1].range),
                                                 length: said[k].range.location - NSMaxRange(said[k - 1].range)))
            return gap.range(of: #"[.!?]\s"#, options: .regularExpression) != nil && said[k].first.isUppercase
        }
        var droppable = [Bool](repeating: false, count: n)
        var marker = [Bool](repeating: false, count: n)  // cue and list words: dropping them takes nothing back
        var cues: [(words: [Int], takesBack: [Int], replacement: Int)] = []
        for m in corrections.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let cue = said.indices.filter { NSLocationInRange(said[$0].range.location, m.range) }
            guard let first = cue.first else { continue }
            var start = first
            while start > 0, !opens[start] { start -= 1 }
            var back: [Int] = []
            if start < first {
                back = Array(max(start, first - 8)..<first)
            } else if first > 0 {
                var prev = first - 1
                while prev > 0, !opens[prev] { prev -= 1 }
                back = Array(max(prev, first - 20)..<first)
            }
            // What replaces it: the rest of its sentence, or the next sentence after a cue that is a whole
            // sentence ("Scratch that.").
            var end = cue[cue.count - 1] + 1
            while end < n, !opens[end] { end += 1 }
            if end == cue[cue.count - 1] + 1, end < n {
                end += 1
                while end < n, !opens[end] { end += 1 }
            }
            for k in cue + back { droppable[k] = true }
            for k in cue { marker[k] = true }
            cues.append((cue, back, end - cue[cue.count - 1] - 1))
        }
        for k in listMarkers(input, said, opens) { droppable[k] = true; marker[k] = true }

        // fits[i][j]: said[i...] can become written[j...] by dropping only droppable words.
        let m = written.count
        var fits = [[Bool]](repeating: [Bool](repeating: false, count: m + 1), count: n + 1)
        fits[n][m] = true
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m, through: 0, by: -1) {
                fits[i][j] = (droppable[i] && fits[i + 1][j]) || (j < m && said[i].word == written[j] && fits[i + 1][j + 1])
            }
        }
        guard fits[0][0] else { return false }
        // One alignment, dropping as early as possible, so a repeated phrase is kept in its corrected copy.
        var kept = [Bool](repeating: false, count: n)
        var j = 0
        for i in 0..<n {
            if droppable[i] && fits[i + 1][j] { continue }
            kept[i] = true
            j += 1
        }
        for c in cues {
            let k = c.words.map { kept[$0] }
            if k.allSatisfy({ $0 }) { continue }                  // the cue stays: nothing was taken back
            if k.contains(true) { return false }                  // half a cue ("or" of "or rather") is not a rewrite
            let takenBack = c.takesBack.filter { !kept[$0] && !marker[$0] }.count
            if c.takesBack.contains(where: { !marker[$0] }) {
                if takenBack == 0 { return false }                // cue gone but nothing taken back
            } else if c.takesBack.contains(where: { kept[$0] }) || c.takesBack.isEmpty {
                return false                                      // a chained cue ("Sorry, I mean") goes with its first cue
            }
            if takenBack > c.replacement + 1 { return false }     // takes back more than what replaces it
            // What a cue takes back is the words right before it: one run ending at the cue, not a word
            // picked out of the clause ("Let's meet Tuesday, Wednesday" drops "on" and keeps Tuesday).
            let words = c.takesBack.filter { !marker[$0] }
            let gone = words.filter { !kept[$0] }
            if gone != Array(words.suffix(gone.count)) { return false }
            // A replacement that repeats the start of what it replaces ("two hundred units, sorry, two hundred and
            // fifty") takes back from that word on, not only the last word ("We need two hundred, two hundred...").
            let last = c.words[c.words.count - 1]
            if let r = (last + 1 < n ? Array(last + 1..<n) : []).first(where: { !marker[$0] }),
               let from = words.lastIndex(where: { said[$0].word == said[r].word }),
               gone != Array(words[from...]) { return false }
        }
        return listNumbersCount(out, from: list)
    }

    /// The model's list numbers go 1, 2, 3 within each list, or on from `from` (the list above the cursor); any
    /// other number at a line start is a new word.
    static func listNumbersCount(_ out: String, from: Int = 0) -> Bool {
        var previous = from
        for m in listNumber.matches(in: out, range: NSRange(location: 0, length: (out as NSString).length)) {
            let n = Int((out as NSString).substring(with: m.range).filter(\.isNumber)) ?? 0
            guard n == 1 || n == previous + 1 else { return false }
            previous = n
        }
        return true
    }

    /// The tokens of list and line-break markers that start an item: "First, ...", ". Number two, ...",
    /// "And finally, ...", ". New line. ...", "Bullet point, ...". Bare counting words ("One, ...") only open a
    /// sentence. So "hire one designer" or "a new line of credit" keep their words. In text with no sentence
    /// punctuation at all, items cannot be told apart, so every marker counts.
    static func listMarkers(_ input: String, _ said: [(word: String, first: Character, range: NSRange)],
                            _ opens: [Bool]) -> [Int] {
        let ns = input as NSString
        let unpunctuated = !input.contains(where: { ".?!".contains($0) })
        // The nearest character before or after `loc` that is not a space; nil at either end of the text.
        func char(_ loc: Int, step: Int) -> Character? {
            var i = step < 0 ? loc - 1 : loc
            while i >= 0, i < ns.length {
                let c = ns.substring(with: NSRange(location: i, length: 1))
                if c != " " { return Character(c) }
                i += step
            }
            return nil
        }
        func charBefore(_ loc: Int) -> Character? { char(loc, step: -1) }
        func charAfter(_ loc: Int) -> Character? { char(loc, step: 1) }
        let punct: Set<Character> = [",", ".", ":", ";", "!", "?"]
        var out: [Int] = []
        // A marker the speech model ran into the clause before it ("for the trip first, the tickets, second, ..."):
        // it counts only when a later marker starts an item, so "do it first, then call" keeps its word.
        var runOn: [[Int]] = []
        for m in listMarker.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let ks = said.indices.filter { NSLocationInRange(said[$0].range.location, m.range) }
            guard let first = ks.first else { continue }
            if !unpunctuated {
                let after = charAfter(NSMaxRange(m.range))
                guard after == nil || punct.contains(after!) else { continue }
                let bare = ks.count == 1 && ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
                    .contains(said[first].word)
                var starts = opens[first]
                var and: Int? = nil
                if !starts, first > 0, said[first - 1].word == "and" {   // "And third, ..."
                    let b = charBefore(said[first - 1].range.location)
                    if opens[first - 1] || b == nil || punct.contains(b!) { starts = true; and = first - 1 }
                }
                if !starts, !bare {
                    let b = charBefore(m.range.location)
                    starts = b == nil || punct.contains(b!)
                    if !starts, after != nil { runOn.append(ks) }
                }
                guard starts else { continue }
                if let and { out.append(and) }
            }
            out += ks
        }
        for ks in runOn where out.contains(where: { $0 > ks[ks.count - 1] }) { out += ks }
        return out
    }

    static func tokens(_ s: String) -> [(word: String, first: Character, range: NSRange)] {
        word.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map {
            let w = (s as NSString).substring(with: $0.range)
            return (w.lowercased(), w.first ?? " ", $0.range)
        }
    }

    static let word = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_'’]+"#)

    static func has(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func replace(_ re: NSRegularExpression, in s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "_") })
            .map(String.init)
    }
}

/// A cleanup model file: a GGUF that the user downloads from the menu into <data>/models.
public struct CleanupModelFile: Equatable, Sendable {
    public let file: String
    public let url: URL
    public let sha256: String
    public let megabytes: Int
}

/// The Cleanup rows of docs/models.md: the default cleanup model for a Mac, nil for rules only.
public func cleanupModel(appleSilicon: Bool, ramGB: Int) -> CleanupModelFile? {
    guard appleSilicon else { return nil }
    return ramGB < 16 ? .qwen35_08b : .qwen35_2b
}

extension CleanupModelFile {
    /// Moves a downloaded file into `dir` under this model's name, only when it has the pinned SHA-256.
    /// A file that does not match is not moved: llama.cpp would parse whatever lands there.
    public func install(_ downloaded: URL, into dir: URL) throws {
        let handle = try FileHandle(forReadingFrom: downloaded)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 24), !chunk.isEmpty { hash.update(data: chunk) }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == sha256 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(file) does not match its checksum"])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: downloaded, to: dir.appendingPathComponent(file))
    }
}

/// The URLs name a Hugging Face commit, not `main`: a re-upload upstream must not break the pinned SHA-256.
extension CleanupModelFile {
    static let qwen35_08b = CleanupModelFile(
        file: "Qwen3.5-0.8B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf")!,
        sha256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517", megabytes: 533)
    static let qwen35_2b = CleanupModelFile(
        file: "Qwen3.5-2B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf")!,
        sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223", megabytes: 1281)
}

/// This Mac's default cleanup model.
public func currentCleanupModel() -> CleanupModelFile? {
    #if arch(arm64)
    let arm = true
    #else
    let arm = false
    #endif
    return cleanupModel(appleSilicon: arm, ramGB: Int(ProcessInfo.processInfo.physicalMemory >> 30))
}
