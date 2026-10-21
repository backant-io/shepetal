import AppKit
import Combine
import ShepetalCore
import SwiftUI

/// The notes in memory, saved to notes.sqlite a moment after the last change (F55). The notes window is the store's
/// only writer, so memory is the truth and the store follows it.
@MainActor
final class NotesModel: ObservableObject {
    /// In the list's order (`Note.precedes`): pinned first, then the newest change.
    @Published private(set) var notes: [Note] = []
    /// The last read or save that failed. The text stays in the editor, so nothing typed is lost while it shows.
    @Published private(set) var problem: String?
    let store: NoteStore
    private let saveDelay: TimeInterval
    private let now: () -> Date
    private var pending: [String: Task<Void, Never>] = [:]
    private var quitting: NSObjectProtocol?

    init(store: NoteStore, saveDelay: TimeInterval = 0.5, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.saveDelay = saveDelay
        self.now = now
        do { notes = try store.list() } catch { problem = "Notes could not be read: \(error.localizedDescription)" }
        // Quit within the delay still saves the last words.
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                          queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.flushAll() } }
    }

    func note(_ id: String) -> Note? { notes.first { $0.id == id } }

    /// An empty note, saved at once, so it is still there after a relaunch.
    func create() -> Note {
        let n = Note(createdAt: now())
        notes.append(n)
        notes.sort(by: Note.precedes)
        write(n.id)
        return n
    }

    /// Typing: memory at once, the store once `saveDelay` passed without another change.
    func edit(_ id: String, title: String, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].title != title || notes[i].body != body else { return }
        notes[i].title = title
        notes[i].body = body
        notes[i].updatedAt = now()
        notes.sort(by: Note.precedes)
        pending[id]?.cancel()
        pending[id] = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: .seconds(saveDelay))
            guard !Task.isCancelled else { return }
            self?.pending[id] = nil
            self?.write(id)
        }
    }

    /// Pinning is not an edit: the note keeps its change time, so unpinning puts it back where it was.
    func setPinned(_ id: String, _ pinned: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].pinned = pinned
        notes.sort(by: Note.precedes)
        pending.removeValue(forKey: id)?.cancel()
        write(id)
    }

    /// A save still waiting for the note is dropped with it, so it cannot write the note back.
    func delete(_ id: String) {
        pending.removeValue(forKey: id)?.cancel()
        notes.removeAll { $0.id == id }
        do { try store.delete(id) } catch { problem = "Not deleted: \(error.localizedDescription)" }
    }

    /// Saves now what is waiting for the delay (the tab closes).
    func flush(_ id: String) {
        guard let waiting = pending.removeValue(forKey: id) else { return }
        waiting.cancel()
        write(id)
    }

    func flushAll() { pending.keys.forEach(flush) }

    private func write(_ id: String) {
        guard let n = note(id) else { return }
        do {
            try store.save(n)
            problem = nil
        } catch { problem = "Not saved: \(error.localizedDescription)" }
    }
}

/// The notes window (F55): one window tab per open note, through the system's tabs, each with the list (pinned
/// first) and its note's editor. Opens from the open-notes shortcut and the 🤫 menu. The notes are plain Markdown in
/// notes.sqlite in the owner-only data dir, never sent anywhere. Dictating into a note is dictating into any app:
/// the paste lands while the note keeps focus (rule 8).
@MainActor
final class NotesWindow: NSObject, NSWindowDelegate {
    let model: NotesModel
    /// The open tabs, the one most recently in front last.
    private(set) var tabs: [(id: String, window: NoteTab)] = []
    private let makeTab: () -> NoteTab
    private let activate: () -> Void
    private var titles: AnyCancellable?

    init(model: NotesModel, makeTab: @escaping () -> NoteTab = { NoteTab() },
         activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.model = model
        self.makeTab = makeTab
        self.activate = activate
        super.init()
        // A tab is named after its note, as the title is typed.
        titles = model.$notes.sink { [weak self] notes in
            MainActor.assumeIsolated {
                for t in self?.tabs ?? [] { t.window.title = Self.title(notes.first { $0.id == t.id }) }
            }
        }
    }

    /// The app's notes: notes.sqlite in the owner-only data dir.
    static func onDisk() throws -> NotesWindow {
        try AudioStore.makeOwnerOnlyDirectory(Paths.root)
        return NotesWindow(model: NotesModel(store: try NoteStore(path: Paths.root.appendingPathComponent("notes.sqlite"))))
    }

    static func title(_ note: Note?) -> String { note.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Untitled" }

    /// The shortcut and the menu: the open notes to the front, else the top note of the list, or a new note.
    func show() {
        if let front = tabs.last?.window { return bringToFront(front) }
        open(model.notes.first?.id ?? model.create().id)
    }

    /// A note from the list: its tab when it is open, else a new tab with the others.
    func open(_ id: String) {
        if let open = tabs.first(where: { $0.id == id }) { return bringToFront(open.window) }
        let tab = makeTab()
        tab.delegate = self
        tab.onNewTab = { [weak self] in self?.newNote() }
        tab.title = Self.title(model.note(id))
        tab.contentView = NSHostingView(rootView: NoteView(model: model, id: id, windows: self))
        if let group = tabs.last?.window { group.addTabbedWindow(tab, ordered: .above) } else { tab.center() }
        tabs.append((id, tab))
        bringToFront(tab)
    }

    func newNote() { open(model.create().id) }

    func delete(_ id: String) {
        model.delete(id)
        tabs.first { $0.id == id }?.window.close()
    }

    private func bringToFront(_ tab: NoteTab) {
        activate()
        tab.makeKeyAndOrderFront(nil)  // selects the tab when it is not the shown one
        inFront(tab)
    }

    private func inFront(_ tab: NoteTab) {
        guard let i = tabs.firstIndex(where: { $0.window === tab }) else { return }
        tabs.append(tabs.remove(at: i))
    }

    /// A tab clicked in the tab bar: new notes join its window.
    func windowDidBecomeKey(_ notification: Notification) {
        if let tab = notification.object as? NoteTab { inFront(tab) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let i = tabs.firstIndex(where: { $0.window === notification.object as? NoteTab }) else { return }
        model.flush(tabs.remove(at: i).id)
    }
}

/// One note's window, a tab of the notes window.
class NoteTab: NSWindow {
    var onNewTab: () -> Void = {}

    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        tabbingMode = .preferred
        tabbingIdentifier = "io.backant.shepetal.notes"
    }

    /// The tab bar's + button.
    override func newWindowForTab(_ sender: Any?) { onNewTab() }

    /// An accessory app has no Edit menu for ⌘V and the other editing keys to reach, so the window sends them to the
    /// text being edited itself. Dictation's paste is one of them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = Self.editAction(event), firstResponder?.tryToPerform(action, with: self) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z ⌘W, by the letter the key types, or by the key's place on a layout without Latin letters
    /// (Cyrillic), where dictation's ⌘V is the V key.
    static func editAction(_ event: NSEvent) -> Selector? {
        let keys: [(letter: String, code: UInt16, modifiers: NSEvent.ModifierFlags, action: Selector)] = [
            ("x", 7, .command, #selector(NSText.cut(_:))),
            ("c", 8, .command, #selector(NSText.copy(_:))),
            ("v", 9, .command, #selector(NSText.paste(_:))),
            ("a", 0, .command, #selector(NSText.selectAll(_:))),
            ("z", 6, .command, Selector(("undo:"))),
            ("z", 6, [.command, .shift], Selector(("redo:"))),
            ("w", 13, .command, #selector(NSWindow.performClose(_:))),
        ]
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let c = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let latin = !c.isEmpty && c.allSatisfy(\.isASCII)
        return keys.first { $0.modifiers == modifiers && (latin ? c == $0.letter : event.keyCode == $0.code) }?.action
    }
}

/// The list (a Pinned section, then the rest) and one note's title and Markdown text, saved as typed.
struct NoteView: View {
    @ObservedObject var model: NotesModel
    let id: String
    weak var windows: NotesWindow?
    @State private var title = ""
    @State private var text = ""
    @State private var confirmDelete = false
    @FocusState private var editing: Bool

    var body: some View {
        HSplitView {
            list.frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            editor.frame(minWidth: 360)
        }
        .frame(minWidth: 600, minHeight: 360)
        .onAppear {
            title = model.note(id)?.title ?? ""
            text = model.note(id)?.body ?? ""
            DispatchQueue.main.async { editing = true }  // dictation lands in the text straight away
        }
    }

    private var list: some View {
        let pinned = model.notes.filter(\.pinned), others = model.notes.filter { !$0.pinned }
        return VStack(spacing: 0) {
            List(selection: Binding<String?>(get: { id }, set: { if let other = $0, other != id { windows?.open(other) } })) {
                if pinned.isEmpty {
                    ForEach(others) { row($0) }
                } else {
                    Section("Pinned") { ForEach(pinned) { row($0) } }
                    if !others.isEmpty { Section("Notes") { ForEach(others) { row($0) } } }
                }
            }
            Divider()
            HStack {
                Button { windows?.newNote() } label: { Label("New note", systemImage: "plus") }.buttonStyle(.borderless)
                Spacer()
            }
            .padding(8)
        }
    }

    private func row(_ n: Note) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NotesWindow.title(n)).lineLimit(1)
            Text(MeetingFormat.date(n.updatedAt, format: "dd.MM.yy HH:mm")).font(.caption).foregroundStyle(.secondary)
        }
        .tag(Optional(n.id))
    }

    private var editor: some View {
        let pinned = model.note(id)?.pinned == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Title", text: $title).textFieldStyle(.plain).font(.title2.weight(.semibold))
                Button { model.setPinned(id, !pinned) } label: {
                    Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
                }
                .help(pinned ? "Unpin" : "Pin to the top of the list")
                Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }.help("Delete this note")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            TextEditor(text: $text).font(.body).focused($editing)
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .padding(12)
        .onChange(of: title) { model.edit(id, title: title, body: text) }
        .onChange(of: text) { model.edit(id, title: title, body: text) }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { windows?.delete(id) }
        } message: {
            Text("It is removed from this Mac. This cannot be undone.")
        }
    }
}
