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
                Psst(mode: context.state.mode)
                Text(context.state.mode.title).font(.headline)
                Spacer()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Psst(mode: context.state.mode) }
                DynamicIslandExpandedRegion(.trailing) { Text(context.state.mode.title) }
            } compactLeading: {
                Psst(mode: context.state.mode)
            } compactTrailing: {
                Text(context.state.mode.title).font(.caption2)
            } minimal: {
                Psst(mode: context.state.mode)
            }
        }
    }
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
