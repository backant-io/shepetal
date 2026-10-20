import ActivityKit
import ShepetalSessionCore
import SwiftUI
import WidgetKit

@main
struct ShepetalWidgets: WidgetBundle {
    var body: some Widget { DictationLiveActivity() }
}

/// 🤫 and the dictation state on the lock screen and in the Dynamic Island while a dictation runs.
struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivity.self) { context in
            HStack {
                Psst(mode: context.mode)
                Text(context.title).font(.headline)
                Spacer()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Psst(mode: context.mode) }
                DynamicIslandExpandedRegion(.trailing) { Text(context.title) }
            } compactLeading: {
                Psst(mode: context.mode)
            } compactTrailing: {
                Text(context.title).font(.caption2)
            } minimal: {
                Psst(mode: context.mode)
            }
        }
    }
}

extension ActivityViewContext<DictationActivity> {
    /// A stale activity means the app stopped updating it (it died): no ring, and it says so.
    var mode: Indicator.Mode { isStale ? .idle : state.mode }
    var title: String { isStale ? "Stopped" : state.mode.title }
}

/// The emoji with the state ring, as in the keyboard corner and on the Mac.
struct Psst: View {
    let mode: Indicator.Mode

    var body: some View {
        Text(Indicator.emoji)
            .font(.system(size: 14))
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(mode.color.map { Color(uiColor: $0) } ?? .clear, lineWidth: 2))
    }
}
