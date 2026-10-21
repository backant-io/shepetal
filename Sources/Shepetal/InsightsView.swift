import AppKit
import ShepetalCore
import SwiftUI

/// Home's Insights (F61, F62): the streak, the 26-week heatmap and the card, from History. Hidden until a
/// dictation was delivered.
struct InsightsSection: View {
    @StateObject private var model: InsightsModel

    init(history: History) { _model = StateObject(wrappedValue: InsightsModel(history: history)) }

    var body: some View {
        if let i = model.insights {
            Section("Insights") {
                Text(InsightsFormat.streak(i.streak)).bold()
                Heatmap(days: i.days, labels: model.labels)
                ForEach(InsightsFormat.card(i), id: \.title) { LabeledContent($0.title, value: $0.value) }
            }
        }
        if !model.problem.isEmpty { Text(model.problem).font(.caption).foregroundStyle(.orange) }
    }
}

/// Loads at once and whenever a window becomes key, so a dictation made in another app shows once the user is
/// back. Not `onAppear`: a hidden section has no view to appear, and would never load the first dictation.
/// ponytail: one full read on the main thread per reload, like Your stats; move off main if history gets large.
@MainActor
final class InsightsModel: ObservableObject {
    @Published private(set) var insights: Insights?
    /// Each square's "21.10.26: 120 words", made once per load rather than on every draw.
    private(set) var labels: [String] = []
    @Published private(set) var problem = ""
    private let history: History
    private var observer: NSObjectProtocol?

    init(history: History) {
        self.history = history
        load()
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func load() {
        do {
            let i = Insights(try history.rows())
            labels = i?.days.map { InsightsFormat.day($0) } ?? []
            insights = i
            problem = ""
        } catch {
            problem = "Insights: \(error.localizedDescription)"
        }
    }
}

/// 7 rows by 26 week columns, today at the bottom of the last one. Each square names its day and words.
private struct Heatmap: View {
    let days: [Insights.Day]
    let labels: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            ForEach(0..<Insights.weeks, id: \.self) { week in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { row in
                        let i = week * 7 + row
                        if i < days.count {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(InsightsFormat.color(days[i].level))
                                .frame(width: 11, height: 11)
                                .help(labels[i])
                                .accessibilityLabel(labels[i])
                        } else {
                            Color.clear.frame(width: 11, height: 11)  // after today
                        }
                    }
                }
            }
        }
    }
}

enum InsightsFormat {
    struct Row: Equatable {
        var title: String
        var value: String
    }

    static func streak(_ days: Int) -> String {
        days == 0 ? "No streak right now: dictate today to start one" : "\(days)-day streak"
    }

    /// Lines without a value (no app recorded, no word or phrase used twice) are left out.
    static func card(_ i: Insights) -> [Row] {
        var rows: [Row] = []
        if let h = i.peakHour { rows.append(Row(title: "Busiest hour", value: String(format: "%02d:00–%02d:00", h, (h + 1) % 24))) }
        if let app = i.topApp { rows.append(Row(title: "Top app", value: app)) }
        if let w = i.topWord { rows.append(Row(title: "Most-used word", value: "“\(w)”")) }
        if let p = i.topPhrase { rows.append(Row(title: "Favourite phrase", value: "“\(p)”")) }
        rows.append(Row(title: "Words so far", value: i.nextMilestone.map { "\(i.words.formatted()) · next milestone \($0.formatted())" }
                                                     ?? i.words.formatted()))
        return rows
    }

    /// "21.10.26: 120 words" (dates as DD.MM.YY).
    static func day(_ d: Insights.Day, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "dd.MM.yy"
        return "\(f.string(from: d.date)): \(d.words.formatted()) \(d.words == 1 ? "word" : "words")"
    }

    static func color(_ level: Int) -> Color {
        level == 0 ? Color.secondary.opacity(0.15) : Color.accentColor.opacity([0.3, 0.5, 0.75, 1][min(level, 4) - 1])
    }
}
