import ShepetalCore
import SwiftUI

/// Settings' Polish (F45): the saved prompts, each a name and what the model is to do with the selection. Saved as
/// they are typed; the 🤫 menu picks the one the hotkey uses.
struct PolishSection: View {
    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var prompt: PolishPrompt
    }

    let defaults: UserDefaults
    let chord: String
    @State private var rows: [Row]

    /// `chord` is the Polish shortcut's label (`Key.label`).
    init(chord: String, defaults: UserDefaults = .standard) {
        self.chord = chord
        self.defaults = defaults
        _rows = State(initialValue: PolishPrompts.load(defaults).map { Row(prompt: $0) })
    }

    var body: some View {
        Section {
            ForEach($rows) { $row in
                TextField("Name", text: $row.prompt.name)
                TextField("What to do with the selected text", text: $row.prompt.instruction, axis: .vertical).lineLimit(2...6)
                if rows.count > 1 { Button("Remove this prompt") { rows.removeAll { $0.id == row.id } } }
            }
            Button("Add prompt") { rows.append(Row(prompt: PolishPrompt(name: "My prompt \(rows.count + 1)", instruction: ""))) }
            Button("Back to the built-in prompts") { rows = PolishPrompts.builtIn.map { Row(prompt: $0) } }
        } header: {
            Text("Polish")
        } footer: {
            Text("Select text in any app and press \(chord): the cleanup model rewrites it on this Mac with the prompt picked under Polish prompt in the 🤫 menu, and the rewrite replaces the selection. If you switch windows while it works, the rewrite goes to the clipboard instead. A prompt without a name or text is not used.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: rows) { PolishPrompts.save(rows.map(\.prompt), defaults) }
    }
}
