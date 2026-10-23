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
        SHRowGroup("Formatting per app") {
            SHRow("Format", title: "All apps") {
                SHSegmented("All apps", selection: $defaultMode,
                            options: [(FormatMode.formatted, "Formatted"), (.raw, "Raw")])
            }
            ForEach(Array(apps.enumerated()), id: \.element.bundleId) { i, app in
                let name = app.name.isEmpty ? app.bundleId : app.name
                SHRow(i == 0 ? "Per app" : "", title: name,
                      help: chosen[app.bundleId] == nil ? "Default: \(defaultMode == .raw ? "Raw" : "Formatted")" : nil) {
                    SHSegmented(name, selection: Binding(
                        get: { chosen[app.bundleId] },
                        set: { format.set($0, for: app.bundleId); chosen = format.apps }),
                                options: [(FormatMode?.none, "Default"), (.some(.formatted), "Formatted"), (.some(.raw), "Raw")])
                }
            }
        } footer: {
            Text("Formatted removes fillers and stutters, runs the cleanup model when it is on, and writes spoken dates as numbers. Raw pastes the words as heard. The dictionary applies in both. An app shows here once you have dictated into it.")
            if !problem.isEmpty { SHErrorLine(problem) }
        }
        .onAppear {
            do { apps = try history.apps(); problem = "" } catch { problem = "History: \(error.localizedDescription)" }
            chosen = format.apps
        }
    }
}
