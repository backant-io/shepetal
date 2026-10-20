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

    public static func apply(_ raw: String, model: CleanupModel?) -> Result {
        let ruled = Cleanup.apply(raw)
        guard let model, needsModel(ruled), let out = try? model.rewrite(ruled), accepts(out, for: ruled) else {
            return Result(text: ruled, usedModel: false)
        }
        return Result(text: out, usedModel: true)
    }

    static let corrections = try! NSRegularExpression(pattern: #"""
        (?xi) \b(?: actually | i\ mean | no,?\ wait | wait,?\ no | scratch\ that | strike\ that | cancel\ that
          | forget\ that | never\ mind | or\ rather | make\ that | sorry | correction | let\ me\ rephrase )\b
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

    /// The model's text is used only when it is still what the user said:
    /// - it has letters ("24" is an answer, not a rewrite);
    /// - at most 1 word in 10 is new; only list numbers at the start of a line are free, so "56" and "144" count;
    /// - nothing said is lost except list and line-break markers, and in a self-correction (a cue in the
    ///   input) the cue plus at most half of the other words, which is what it takes back.
    /// ponytail: word sets, not meaning; a correction that keeps the wrong half of the words gets through.
    public static func accepts(_ out: String, for input: String) -> Bool {
        guard out.contains(where: \.isLetter) else { return false }
        let said = Set(words(input))
        let written = words(replace(listNumber, in: out))
        guard written.filter({ !said.contains($0) }).count * 10 <= written.count else { return false }
        let content = Set(words(replace(corrections, in: input))).subtracting(layoutWords)
        let lost = content.subtracting(written)
        return has(corrections, input) ? lost.count * 2 <= content.count : lost.isEmpty
    }

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

extension CleanupModelFile {
    static let qwen35_08b = CleanupModelFile(
        file: "Qwen3.5-0.8B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf")!,
        sha256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517", megabytes: 533)
    static let qwen35_2b = CleanupModelFile(
        file: "Qwen3.5-2B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!,
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
