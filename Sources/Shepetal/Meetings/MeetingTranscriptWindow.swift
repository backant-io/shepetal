import AppKit
import ShepetalCore
import SwiftUI

/// "Meeting transcript": opens by itself when a recorded meeting's whole transcript is stored, with the summary
/// added when it lands. It comes to the front without taking focus from the app you are in (rule 8): a
/// non-activating panel ordered front, never NSApp.activate, that becomes key only when clicked. One panel,
/// reused: the latest meeting replaces the one shown. The clipboard is written only from its Copy buttons or ⌘C.
@MainActor
final class MeetingTranscriptWindow {
    let panel: NSPanel = TranscriptPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                                         styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
    let model: MeetingsModel
    private let present: @MainActor (NSPanel) -> Void

    /// Like `MeetingCard`: tests pass a `present` that only counts, so nothing shows, and a model with its own copy.
    init(model: MeetingsModel, open: @escaping (String) -> Void,
         present: @escaping @MainActor (NSPanel) -> Void = { $0.orderFrontRegardless() }) {
        self.model = model
        self.present = present
        panel.title = "Meeting transcript"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false  // an accessory app is never active
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]  // over a full-screen call too
        panel.contentView = NSHostingView(rootView: MeetingTranscriptView(model: model, open: open))
        panel.center()
    }

    func show(_ meeting: Meeting) {
        model.select(meeting.id)
        present(panel)
    }
}

/// An accessory app has no Edit menu for ⌘C to reach, so the panel sends copy: to the selected text itself.
private final class TranscriptPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "c" {
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct MeetingTranscriptView: View {
    @ObservedObject var model: MeetingsModel
    let open: (String) -> Void

    var body: some View {
        Group {
            if let r = model.record { content(r) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 460, minHeight: 320)
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(MeetingFormat.headline(r.meeting)).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button { model.copyTranscript() } label: { Label("Copy transcript", systemImage: "text.quote") }
                        .disabled(r.segments.isEmpty)
                    Button { model.copySummary() } label: { Label("Copy summary", systemImage: "doc.on.doc") }
                        .disabled(r.summary == nil || r.segments.isEmpty)
                    Spacer(minLength: 8)
                    Button("Open in Meetings") { open(r.meeting.id) }
                }
            }
            .padding(16)
            Divider()
            if r.segments.isEmpty {
                ContentUnavailableView("No speech was recorded", systemImage: "waveform",
                                       description: Text("Nothing was transcribed in this meeting."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary(r.summary)
                        Divider()
                        LazyVStack(spacing: 12) {
                            ForEach(Array(r.segments.enumerated()), id: \.offset) { _, s in Bubble(segment: s) }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    @ViewBuilder private func summary(_ s: Summary?) -> some View {
        if let s {
            VStack(alignment: .leading, spacing: 10) {
                if !s.overview.isEmpty { Text(s.overview).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if !s.actionItems.isEmpty {
                    Text("Action items").font(.headline)
                    ForEach(Array(s.actionItems.enumerated()), id: \.offset) { _, a in ActionRow(item: a) }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Summarizing…").foregroundStyle(.secondary)
            }
        }
    }
}
