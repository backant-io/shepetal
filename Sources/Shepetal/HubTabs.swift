import AppKit
import ShepetalCore
import SwiftUI

/// F91: the hub's Dictionary tab. dictionary.txt's entries (F39), changed one line at a time through Vocabulary,
/// so the file keeps the user's comments and stays owner-only. Dictation reads the file again each time.
@MainActor
final class DictionaryModel: ObservableObject {
    let url: URL
    let editAsText: () -> Void
    @Published private(set) var entries: [Vocabulary.Entry] = []
    @Published private(set) var message = ""

    init(url: URL, editAsText: @escaping () -> Void) {
        self.url = url
        self.editAsText = editAsText
    }

    func reload() { entries = Vocabulary.load(url).entries }

    /// A word or phrase, written exactly so; with a replacement, what is said becomes the replacement.
    /// An entry for the same words is changed (its star kept) instead of added twice. False when nothing was added.
    @discardableResult
    func add(_ words: String, replacement: String = "") -> Bool {
        let w = words.trimmingCharacters(in: .whitespaces), r = replacement.trimmingCharacters(in: .whitespaces)
        let parsed = Vocabulary(r.isEmpty ? w : "\(w) => \(r)").entries  // the file's own rules: no comment, no blank
        guard parsed.count == 1, var new = parsed.first else {
            message = "Type one word or phrase"
            return false
        }
        let old = entries.first { $0.spoken.caseInsensitiveCompare(new.spoken) == .orderedSame }
        new.starred = new.starred || old?.starred == true
        return change(old, new)
    }

    func remove(_ e: Vocabulary.Entry) { change(e, nil) }

    func toggleStar(_ e: Vocabulary.Entry) {
        var s = e
        s.starred.toggle()
        change(e, s)
    }

    @discardableResult
    private func change(_ old: Vocabulary.Entry?, _ new: Vocabulary.Entry?) -> Bool {
        defer { reload() }
        do {
            guard try Vocabulary.update(url, replacing: old, with: new) else {
                message = "dictionary.txt was changed elsewhere. This is what it holds now."
                return false
            }
            message = ""
            return true
        } catch {
            message = "Dictionary: \(error.localizedDescription)"
            return false
        }
    }
}

struct DictionaryTab: View {
    @ObservedObject var model: DictionaryModel
    @State private var words = ""
    @State private var replacement = ""

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Word or phrase", text: $words)
                TextField("Replace with (optional)", text: $replacement)
                Button("Add") { if model.add(words, replacement: replacement) { words = ""; replacement = "" } }
                    .disabled(words.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { if model.add(words, replacement: replacement) { words = ""; replacement = "" } }
            List(Array(model.entries.enumerated()), id: \.offset) { _, e in row(e) }
                .overlay { if model.entries.isEmpty { Text("No words yet").foregroundStyle(.secondary) } }
            HStack {
                Text(model.message.isEmpty
                     ? "Words are written exactly as listed. Starred ones go first in the hint to speech recognition. Changes apply on your next dictation."
                     : model.message)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit as text…", action: model.editAsText)
            }
        }
        .onAppear(perform: model.reload)
    }

    private func row(_ e: Vocabulary.Entry) -> some View {
        HStack {
            Button { model.toggleStar(e) } label: { Image(systemName: e.starred ? "star.fill" : "star") }
                .buttonStyle(.borderless)
                .help(e.starred ? "Unstar" : "Star: goes first in the hint to speech recognition")
                .accessibilityLabel(e.starred ? "Unstar \(e.spoken)" : "Star \(e.spoken)")
            Text(e.isReplacement ? "\(e.spoken) → \(e.written)" : e.written).textSelection(.enabled)
            Spacer()
            Button("Remove") { model.remove(e) }
        }
    }
}

/// F91: the 🤫 menu's Shortcuts…, Microphone and Languages, in the hub's Settings tab. These are the same
/// controllers' menus (`Mic.menuItem`, `SpeechMenu.languagesItem`), built again at each click, so the
/// window and the menu always show the same choice.
struct HubInput {
    var microphone: () -> NSMenuItem
    var languages: () -> NSMenuItem
    var openShortcuts: () -> Void

    static let none = HubInput(microphone: { NSMenuItem() }, languages: { NSMenuItem() }, openShortcuts: {})
}

struct HubInputSettings: View {
    let input: HubInput

    var body: some View {
        LabeledContent("Microphone") { MenuPopUpButton(title: "Choose…", item: input.microphone).fixedSize() }
        LabeledContent("Languages") { MenuPopUpButton(title: "Choose…", item: input.languages).fixedSize() }
        Button("Shortcuts…", action: input.openShortcuts)
    }
}

/// A push button that pops `item()`'s submenu up under itself.
struct MenuPopUpButton: NSViewRepresentable {
    let title: String
    let item: () -> NSMenuItem

    func makeCoordinator() -> Coordinator { Coordinator(item) }

    func makeNSView(context: Context) -> NSButton {
        NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.pop(_:)))
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        context.coordinator.item = item
    }

    @MainActor
    final class Coordinator: NSObject {
        var item: () -> NSMenuItem
        init(_ item: @escaping () -> NSMenuItem) { self.item = item }

        var menu: NSMenu? { item().submenu }

        @objc func pop(_ sender: NSButton) {
            menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
        }
    }
}
