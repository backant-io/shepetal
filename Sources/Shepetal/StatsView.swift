import AppKit
import ShepetalCore
import SwiftUI

/// Home's "Your stats" (F60): the last 7 days next to all time, from History. It reloads when it appears and
/// whenever a window becomes key, so dictations made in other apps show once the user is back in the window.
/// ponytail: two queries on the main thread per reload; move off main if history grows to tens of thousands of rows.
struct StatsSection: View {
    let history: History
    /// `defaults write io.backant.shepetal typingWpm 60` changes the typing speed "time saved" is measured against.
    @AppStorage("typingWpm") private var typingWpm = DictationStats.defaultTypingWpm
    @State private var week = DictationStats()
    @State private var all = DictationStats()
    @State private var problem = ""

    var body: some View {
        SHRowGroup("Your stats") {
            SHContentRow("") {
                columns(Text("Last 7 days"), Text("All time"))
                    .shText(SH.label).foregroundStyle(SH.textMuted)
            }
            ForEach(StatsFormat.rows(week: week, all: all), id: \.title) { r in
                SHContentRow(r.title) {
                    columns(Text(r.week), Text(r.all))  // top apps span lines
                        .shText(SH.appBody).foregroundStyle(SH.text)
                }
            }
        } footer: {
            Text("Time saved: typing the same words at \(Int(typingWpm)) words per minute, minus the time spent speaking.")
            if !problem.isEmpty { SHErrorLine(problem) }
        }
        .onAppear(perform: load)
        .onChange(of: typingWpm) { load() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in load() }
    }

    /// The last 7 days and all time, in two columns of the same width.
    private func columns(_ week: Text, _ all: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.space5) {
            week.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            all.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() {
        do {
            week = try history.stats(since: Date().addingTimeInterval(-7 * 86_400), typingWpm: typingWpm)
            all = try history.stats(typingWpm: typingWpm)
            problem = ""
        } catch {
            problem = "Stats: \(error.localizedDescription)"
        }
    }
}

enum StatsFormat {
    struct Row: Equatable {
        var title: String
        var week: String
        var all: String
    }

    static func rows(week: DictationStats, all: DictationStats) -> [Row] {
        func row(_ title: String, _ f: (DictationStats) -> String) -> Row { Row(title: title, week: f(week), all: f(all)) }
        return [
            row("Words") { $0.words.formatted() },
            row("Dictations") { $0.dictations.formatted() },
            row("Words per minute") { Int($0.wpm.rounded()).formatted() },
            row("Speaking time") { duration($0.speakingMinutes) },
            row("Time saved") { duration($0.timeSavedMinutes) },
            row("Top apps") { s in s.apps.isEmpty ? "–" : s.apps.prefix(3).map { "\($0.app): \($0.words.formatted())" }.joined(separator: "\n") },
        ]
    }

    /// "45 s" under a minute, "12 min" under an hour, then "2 h 5 min".
    static func duration(_ minutes: Double) -> String {
        let seconds = Int((minutes * 60).rounded())
        if seconds < 60 { return "\(seconds) s" }
        let m = Int(minutes.rounded())
        return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }
}
