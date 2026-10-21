import ShepetalCore
import SwiftUI

/// Settings' "Formatting per app" (F33): Formatted or Raw for all apps, and Default, Formatted or Raw for each app
/// in History. The apps are read again whenever the section appears.
struct AppFormatSection: View {
    let history: History
    var format = AppFormat()
    @AppStorage(AppFormat.defaultKey) private var defaultMode = FormatMode.formatted
    @State private var apps: [(name: String, bundleId: String)] = []
    @State private var chosen: [String: FormatMode] = [:]
    @State private var problem = ""

    var body: some View {
        Section("Formatting per app") {
            Picker("All apps", selection: $defaultMode) {
                Text("Formatted").tag(FormatMode.formatted)
                Text("Raw").tag(FormatMode.raw)
            }
            ForEach(apps, id: \.bundleId) { app in
                Picker(app.name.isEmpty ? app.bundleId : app.name, selection: Binding(
                    get: { chosen[app.bundleId] },
                    set: { format.set($0, for: app.bundleId); chosen = format.apps })) {
                    Text("Default (\(defaultMode == .raw ? "Raw" : "Formatted"))").tag(FormatMode?.none)
                    Text("Formatted").tag(FormatMode?.some(.formatted))
                    Text("Raw").tag(FormatMode?.some(.raw))
                }
            }
            Text("Formatted removes fillers and stutters, runs the cleanup model when it is on, and writes spoken dates as numbers. Raw pastes the words as heard. The dictionary applies in both. An app shows here once you have dictated into it.")
                .font(.caption).foregroundStyle(.secondary)
            if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(.orange) }
        }
        .onAppear {
            do { apps = try history.apps(); problem = "" } catch { problem = "History: \(error.localizedDescription)" }
            chosen = format.apps
        }
    }
}
