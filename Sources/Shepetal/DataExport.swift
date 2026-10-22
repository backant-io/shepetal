import AppKit
import ShepetalCore
import SwiftUI

/// F64: Settings' "Export my data…" writes everything shepetal keeps, except notes (F55, not exported yet: #256),
/// into one owner-only folder the user picked:
/// history.json and history.csv (every dictation, archived ones too), dictionary.json and a copy of
/// dictionary.txt, meetings.json, and one Markdown file per meeting. Recordings are not copied: the rows name
/// their paths, and "Open recordings folder" has them. Model names are left out (they never reach the user).
enum DataExport {
    /// One history row. Dates are ISO 8601 in the JSON.
    struct Dictation: Codable, Equatable {
        var id: String
        var createdAt: Date
        var outcome: String
        var app: String
        var bundleId: String
        var url: String
        var durationMs: Int
        var rawText: String
        var text: String
        var archived: Bool
        var reverted: Bool  // History's Show raw (F48)
        var audioPath: String

        init(_ e: HistoryEntry) {
            id = e.id; createdAt = e.createdAt; outcome = e.outcome.rawValue; app = e.app; bundleId = e.bundleId
            url = e.url; durationMs = e.durationMs; rawText = e.rawText; text = e.text; archived = e.archived
            reverted = e.reverted; audioPath = e.audioPath
        }
    }

    /// dictionary.json, the format the dictionary import (F117) reads.
    struct DictionaryFile: Codable, Equatable {
        struct Word: Codable, Equatable {
            var spoken: String
            var written: String
            var starred: Bool
        }
        var dictionary: [Word]
    }

    struct MeetingExport: Codable, Equatable {
        var meeting: Meeting
        var segments: [Segment]
        /// Absent until the meeting was summarized.
        var summary: Summary?
        var notes: String  // typed in the Meetings tab (F71)
    }

    static let csvColumns = ["created", "outcome", "app", "url", "text", "raw_text", "duration_ms", "archived", "audio_path", "id"]

    /// Writes `shepetal-export-<yyyy-MM-dd>` (or `-2`, `-3`… when that exists) into `parent` and returns it.
    /// The folder is 0700 and every file in it 0600. On any failure the folder is removed and the error thrown.
    static func write(into parent: URL, history: History, meetings: MeetingStoring, dictionary: URL,
                      now: Date = Date(), timeZone: TimeZone = .current) throws -> URL {
        let fm = FileManager.default
        let base = "shepetal-export-" + MeetingFormat.date(now, timeZone: timeZone, format: "yyyy-MM-dd")
        var folder = parent.appendingPathComponent(base)
        var n = 1
        while fm.fileExists(atPath: folder.path) { n += 1; folder = parent.appendingPathComponent("\(base)-\(n)") }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try fill(folder, history: history, meetings: meetings, dictionary: dictionary, timeZone: timeZone)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return folder
    }

    private static func fill(_ folder: URL, history: History, meetings: MeetingStoring, dictionary: URL, timeZone: TimeZone) throws {
        let fm = FileManager.default
        let json = JSONEncoder()
        json.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        json.dateEncodingStrategy = .iso8601
        func save(_ name: String, _ data: Data, in dir: URL = folder) throws {
            let url = dir.appendingPathComponent(name)
            guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        let rows = try history.search("", includeArchived: true, limit: Int.max)
        try save("history.json", json.encode(rows.map(Dictation.init)))
        try save("history.csv", Data(csv(rows, timeZone: timeZone).utf8))

        let words = Vocabulary.load(dictionary).entries.map { DictionaryFile.Word(spoken: $0.spoken, written: $0.written, starred: $0.starred) }
        try save("dictionary.json", json.encode(DictionaryFile(dictionary: words)))
        if let text = fm.contents(atPath: dictionary.path) { try save("dictionary.txt", text) }

        let records = try meetings.list(limit: Int.max).compactMap { try meetings.get($0.id) }
        try save("meetings.json", json.encode(records.map { MeetingExport(meeting: $0.meeting, segments: $0.segments, summary: $0.summary, notes: $0.notes) }))
        let dir = folder.appendingPathComponent("meetings")
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var used: Set<String> = []
        for r in records.reversed() {
            // Oldest first: a second meeting in the same app and minute gets "… 2.md", never the first one's file.
            let name = String(MeetingFormat.filename(r.meeting, timeZone: timeZone).dropLast(3))
            var file = name + ".md", n = 1
            while used.contains(file) { n += 1; file = "\(name) \(n).md" }
            used.insert(file)
            try save(file, Data(MeetingFormat.markdown(r, timeZone: timeZone).utf8), in: dir)
        }
    }

    /// RFC 4180: every field quoted, quotes doubled, CRLF line ends. Dates are DD.MM.YY.
    static func csv(_ rows: [HistoryEntry], timeZone: TimeZone = .current) -> String {
        func line(_ fields: [String]) -> String {
            fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") + "\r\n"
        }
        return line(csvColumns) + rows.map { e in
            line([MeetingFormat.date(e.createdAt, timeZone: timeZone, format: "dd.MM.yy HH:mm:ss"), e.outcome.rawValue,
                  e.app, e.url, e.text, e.rawText, String(e.durationMs), e.archived ? "yes" : "no", e.audioPath, e.id])
        }.joined()
    }
}

/// The Settings row: a folder panel first (nothing is written without it), then the export, shown in Finder.
struct DataExportButton: View {
    let history: History
    let meetings: MeetingStoring
    @State private var message = ""

    var body: some View {
        Button("Export my data…", action: export)
        Text(message.isEmpty ? "History, dictionary and meetings as JSON, CSV and Markdown. Recordings stay in the recordings folder; the export lists their paths."
                             : message)
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "shepetal puts a shepetal-export folder here."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let folder = try DataExport.write(into: url, history: history, meetings: meetings, dictionary: Paths.dictionary)
            message = "Exported to \(folder.path)"
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}
