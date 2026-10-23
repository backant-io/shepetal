import AppKit
import ShepetalCore
import ShepetalSummary
import SwiftUI

/// "Meeting transcript": opens by itself when a recorded meeting's whole transcript is stored, with the summary
/// added when it lands. It comes to the front without taking focus from the app you are in (rule 8): a
/// non-activating panel ordered front, never NSApp.activate, that becomes key only when clicked. One panel,
/// reused: the latest meeting replaces the one shown. The clipboard is written only from its Copy buttons or ⌘C.
@MainActor
final class MeetingTranscriptWindow {
    let panel: TranscriptPanel
    let model: MeetingsModel
    let hosting: NSHostingView<MeetingTranscriptView>
    private let open: (String) -> Void

    /// Tests pass a panel that only records what it is asked to do, so nothing shows, and a model with its own copy.
    init(model: MeetingsModel, open: @escaping (String) -> Void, panel: TranscriptPanel? = nil) {
        let panel = panel ?? TranscriptPanel()
        self.model = model
        self.open = open
        self.panel = panel
        hosting = NSHostingView(rootView: MeetingTranscriptView(model: model, open: open, summarizing: true))
        panel.title = "Meeting transcript"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false  // an accessory app is never active
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]  // over a full-screen call too
        panel.contentView = hosting
        panel.center()
    }

    /// One window for every meeting `flow` finishes, made at the first one: the latest replaces the one shown.
    /// Returns what the 🤫 menu's Past meetings call: a past meeting in that same window, in front.
    static func follow(_ flow: MeetingFlow, open: @escaping (String) -> Void,
                       panel: @escaping @MainActor () -> TranscriptPanel = { TranscriptPanel() }) -> (Meeting) -> Void {
        var window: MeetingTranscriptWindow?
        let shared = { [store = flow.store] () -> MeetingTranscriptWindow in
            let w = window ?? MeetingTranscriptWindow(model: MeetingsModel(store: store), open: open, panel: panel())
            window = w
            return w
        }
        flow.onTranscript = { m, summarizing in shared().show(m, summarizing: summarizing) }
        return { shared().show($0, summarizing: false, front: true) }
    }

    /// `summarizing` false: no summary is coming (the final pass or the summary failed), so none is promised.
    /// The same meeting again only updates the window; a window the user closed stays closed, unless `front`
    /// (they chose it in the 🤫 menu).
    func show(_ meeting: Meeting, summarizing: Bool = true, front: Bool = false) {
        let shown = model.selectedID == meeting.id
        model.select(meeting.id)
        hosting.rootView = MeetingTranscriptView(model: model, open: open, summarizing: summarizing)
        if !shown || front { panel.orderFrontRegardless() }
    }
}

/// An accessory app has no Edit menu for ⌘C to reach, so the panel sends copy: to the selected text itself.
class TranscriptPanel: NSPanel {
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                  styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        Self.isCopy(event) ? NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) : super.performKeyEquivalent(with: event)
    }

    /// ⌘C with Caps Lock on or off, and on a layout whose C key types another letter (Cyrillic "с").
    static func isCopy(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return false }
        let c = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return c == "c" || (!c.allSatisfy(\.isASCII) && event.keyCode == 8)  // 8: the C key (kVK_ANSI_C)
    }
}

struct MeetingTranscriptView: View {
    @ObservedObject var model: MeetingsModel
    let open: (String) -> Void
    /// The summary is still being written; false once it failed, so nothing spins for ever.
    let summarizing: Bool

    var body: some View {
        Group {
            if let r = model.record { content(r) } else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 460, minHeight: 320)
        .background(SH.bg)
        // ponytail: polls like the Meetings tab, so the summary shows up when it lands.
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func content(_ r: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SH.space3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(MeetingFormat.headline(r.meeting)).shText(SH.appHeading).foregroundStyle(SH.text).lineLimit(1)
                    Spacer(minLength: SH.space2)
                    Text(model.message).shText(SH.appSmall).foregroundStyle(SH.textMuted).lineLimit(1)
                }
                HStack(spacing: SH.space2) {
                    MeetingTool("Copy transcript", icon: .textQuote, variant: .secondary) { model.copyTranscript() }
                        .disabled(r.segments.isEmpty)
                    MeetingTool("Copy summary", icon: .copy, variant: .secondary) { model.copySummary() }
                        .disabled(!model.canCopySummary)
                    Spacer(minLength: SH.space2)
                    Button("Open in Meetings") { open(r.meeting.id) }.buttonStyle(.keycap(.quiet, .sm))
                }
            }
            .padding(.horizontal, SH.space5).padding(.top, SH.space4).padding(.bottom, SH.space3)
            Rectangle().fill(SH.border).frame(height: 1)
            if r.segments.isEmpty && r.transcriptDeletedAt == nil {
                MeetingsEmpty("No speech was recorded", icon: .captions, detail: "Nothing was transcribed in this meeting.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: SH.space5) {
                        summary(r)
                        Rectangle().fill(SH.border).frame(height: 1)
                        if let deleted = MeetingFormat.transcriptDeleted(r) {  // F81: the summary stays
                            VStack(alignment: .leading, spacing: SH.space1) {
                                Text(deleted.title).shText(SH.appHeading).foregroundStyle(SH.text)
                                Text(deleted.detail).shText(SH.appBody).foregroundStyle(SH.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        LazyVStack(spacing: SH.space3) {
                            ForEach(Array(r.segments.enumerated()), id: \.offset) { _, s in Bubble(segment: s) }
                        }
                    }
                    .padding(SH.space5)
                }
            }
        }
    }

    /// The same sections as the Meetings tab, your notes first, so what shows here is what Copy summary copies.
    @ViewBuilder private func summary(_ r: MeetingRecord) -> some View {
        let notes = noteLines(r.notes)
        if r.summary == nil && summarizing {
            Text("Summarizing…").shText(SH.appBody).foregroundStyle(SH.textMuted)
        } else if !notes.isEmpty || !(r.summary?.isEmpty ?? true) {
            SummarySections(summary: r.summary ?? Summary(overview: ""), notes: notes).textSelection(.enabled)
        } else {
            Text("No summary for this meeting").shText(SH.appBody).foregroundStyle(SH.textMuted)
        }
    }
}
