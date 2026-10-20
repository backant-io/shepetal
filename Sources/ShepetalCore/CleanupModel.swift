import CryptoKit
import Foundation

/// A local text model that rewrites dictation (goal rule 5): self-corrections, spoken lists, punctuation and
/// spoken line breaks. `ShepetalCleanup.LlamaCleanup` is the real one (llama.cpp); tests use a fake.
/// One call at a time.
public protocol CleanupModel: AnyObject, Sendable {
    var name: String { get }
    /// Text that already went through `Cleanup.apply` in, rewritten text out.
    func rewrite(_ text: String) throws -> String
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

    public static func apply(_ raw: String, model: CleanupModel?) -> Result {
        let ruled = Cleanup.apply(raw)
        guard let model, needsModel(ruled), words(ruled).count <= maxModelWords,
              let out = try? model.rewrite(ruled), accepts(out, for: ruled) else {
            return Result(text: ruled, usedModel: false)
        }
        return Result(text: out, usedModel: true)
    }

    static let corrections = try! NSRegularExpression(pattern: #"""
        (?xi) (?:,\ )? \b(?: actually,?\ no | actually | i\ mean | no,?\ wait | wait,?\ no | scratch\ that | strike\ that
          | cancel\ that | forget\ that | never\ mind | or\ rather | make\ that | sorry | correction | let\ me\ rephrase )\b
        | ,\ no\b
        """#)
    static let layout = try! NSRegularExpression(pattern: #"""
        (?xi) \b(?: first | second | third | finally | number\ (?:one|two|1|2) | step\ (?:one|two|1|2) | bullet\ point
          | new\ line | new\ paragraph )\b
        | \bone,.*\btwo,
        """#)
    /// The spoken words a list or line break turns into layout.
    static let layoutWords: Set = ["first", "second", "third", "fourth", "fifth", "finally", "and", "number", "step",
                                   "one", "two", "three", "four", "five", "bullet", "point", "new", "line", "paragraph"]
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
    public static func accepts(_ out: String, for input: String) -> Bool {
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
        if has(layout, input) {
            for k in said.indices where layoutWords.contains(said[k].word) { droppable[k] = true; marker[k] = true }
        }

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
        }
        return true
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
