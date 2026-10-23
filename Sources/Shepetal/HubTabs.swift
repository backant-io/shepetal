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

/// The Dictionary screen: a word (and what it replaces) added with the one primary keycap, then the entries as
/// rows. A replacement shows what is said in the mono label column and what is written beside it; the star and
/// Remove are quiet tools on the right.
struct DictionaryTab: View {
    @ObservedObject var model: DictionaryModel
    @State private var words = ""
    @State private var replacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SH.space5) {
            Text("Dictionary").shText(SH.appTitle).foregroundStyle(SH.text)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .bottom, spacing: SH.space3) {
                SHField("Word or phrase") {
                    TextField("e.g. Saoirse", text: $words).textFieldStyle(.shField)
                }
                SHField("Replace with (optional)") {
                    TextField("e.g. maya@example.com", text: $replacement).textFieldStyle(.shField)
                }
                Button("Add", action: add)
                    .buttonStyle(.keycap(.primary))
                    .disabled(words.trimmingCharacters(in: .whitespaces).isEmpty)
                    .alignmentGuide(.bottom) { $0[.bottom] - 4 }  // the cap's foot on the fields' baseline, its side below
            }
            .onSubmit(add)
            entries
            HStack(alignment: .firstTextBaseline, spacing: SH.space5) {
                Text(model.message.isEmpty
                     ? "Words are written exactly as listed. Starred ones go first in the hint to speech recognition. Changes apply on your next dictation."
                     : model.message)
                    .shText(SH.appSmall).foregroundStyle(SH.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit as text…", action: model.editAsText).buttonStyle(.keycap(.secondary, .sm))
            }
        }
        .padding(SH.space5)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: model.reload)
    }

    private func add() {
        if model.add(words, replacement: replacement) { words = ""; replacement = "" }
    }

    @ViewBuilder private var entries: some View {
        if model.entries.isEmpty {
            Text("No words yet").shText(SH.appBody).foregroundStyle(SH.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shHairline(.top)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.entries.enumerated()), id: \.offset) { _, e in row(e) }
                }
                .shHairline(.top)
                .padding(.horizontal, 6)  // room for the tools' focus ring
            }
            .padding(.horizontal, -6)
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ e: Vocabulary.Entry) -> some View {
        HStack(alignment: .center, spacing: SH.space5) {
            HStack(alignment: .firstTextBaseline, spacing: SH.space5) {
                Text(e.isReplacement ? e.spoken : "").shText(SH.label).foregroundStyle(SH.textMuted)
                    .frame(width: SH.rowLabel, alignment: .leading)
                Text(e.written).shText(SH.appBody).foregroundStyle(SH.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(e.isReplacement ? "\(e.spoken) → \(e.written)" : e.written)
            HStack(spacing: SH.space1) {
                Button { model.toggleStar(e) } label: { StarIcon(starred: e.starred) }
                    .buttonStyle(.keycap(.quiet, .sm))
                    .help(e.starred ? "Unstar" : "Star: goes first in the hint to speech recognition")
                    .accessibilityLabel(e.starred ? "Unstar \(e.spoken)" : "Star \(e.spoken)")
                Button { model.remove(e) } label: { Label { Text("Remove") } icon: { SHIcon(.trash) } }
                    .buttonStyle(.keycap(.quiet, .sm))
            }
        }
        .padding(.vertical, 6)
        .shHairline(.bottom)
    }
}

/// Lucide's star: an outline, filled with the text color when the entry is starred, so the two differ by shape.
private struct StarIcon: View {
    let starred: Bool

    var body: some View {
        ZStack {
            if starred { SHIconShape(path: SHIconName.star.path).fill() }
            SHIcon(.star)
        }
        .frame(width: 16, height: 16)
        .foregroundStyle(starred ? SH.text : SH.textMuted)
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

/// Three rows for the Settings screen: put them in `SHRows` with the screen's other rows.
struct HubInputSettings: View {
    let input: HubInput

    var body: some View {
        SHRow("Microphone", title: "The mic you dictate into") { HubMenuPicker(title: "Choose…", item: input.microphone) }
        SHRow("Languages", title: "The languages you speak") { HubMenuPicker(title: "Choose…", item: input.languages) }
        SHRow("Shortcuts", title: "Keys to talk, paste and copy") {
            Button("Shortcuts…", action: input.openShortcuts).buttonStyle(.keycap(.secondary, .sm))
        }
    }
}

/// A small secondary keycap with a chevron that pops the menu up under itself. The cap is drawn here; the click
/// and keyboard focus are the AppKit button's on top of it, so the menu is the controller's own NSMenu, set in
/// Archivo. It stays down while its menu is open.
struct HubMenuPicker: View {
    let title: String
    let item: () -> NSMenuItem

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false
    @State private var focused = false

    var body: some View {
        HStack(spacing: SH.space2) {
            Text(title).shText(SH.appStrong.with(size: 13))
            SHIcon(.chevronDown)
        }
        .foregroundStyle(SH.text)
        .padding(.horizontal, 12)
        .frame(minHeight: SH.controlSm)
        .background(SH.keyFill(scheme), in: RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
        .shShadow(pressed ? SH.keyDown(scheme) : SH.key(scheme), radius: SH.radiusSm)
        .offset(y: pressed ? SH.travel : 0)
        .animation(pressed ? SH.press(reduce: reduceMotion) : SH.settle(reduce: reduceMotion), value: pressed)
        .accessibilityHidden(true)  // the button on top carries the name and the action
        .overlay { MenuPopUpButton(title: title, item: item, pressed: $pressed, focused: $focused) }
        .shFocusRing(focused)
        .padding(.bottom, 3)  // the room its side needs
        .fixedSize()
    }
}

/// A push button that pops `item()`'s submenu up under itself. It draws nothing (HubMenuPicker draws the cap)
/// and reports when it is held down and when it has keyboard focus.
struct MenuPopUpButton: NSViewRepresentable {
    let title: String
    let item: () -> NSMenuItem
    var pressed: Binding<Bool> = .constant(false)
    var focused: Binding<Bool> = .constant(false)

    func makeCoordinator() -> Coordinator { Coordinator(item) }

    func makeNSView(context: Context) -> NSButton {
        let button = Trigger(title: title, target: context.coordinator, action: #selector(Coordinator.pop(_:)))
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none  // the sh-focus ring is drawn around the cap
        update(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        context.coordinator.item = item
        update(button)
    }

    private func update(_ button: NSButton) {
        guard let trigger = button as? Trigger else { return }
        let pressed = pressed, focused = focused
        trigger.pressed = { pressed.wrappedValue = $0 }
        trigger.focused = { focused.wrappedValue = $0 }
    }

    final class Trigger: NSButton {
        var pressed: (Bool) -> Void = { _ in }
        var focused: (Bool) -> Void = { _ in }

        override func mouseDown(with event: NSEvent) {
            pressed(true)
            super.mouseDown(with: event)  // tracks the click, then the menu runs until it closes
            pressed(false)
        }

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { focused(true) }
            return ok
        }

        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok { focused(false) }
            return ok
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var item: () -> NSMenuItem
        init(_ item: @escaping () -> NSMenuItem) { self.item = item }

        var menu: NSMenu? { item().submenu }

        @objc func pop(_ sender: NSButton) {
            guard let menu else { return }
            menu.font = SH.appBody.nsFont
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
        }
    }
}
