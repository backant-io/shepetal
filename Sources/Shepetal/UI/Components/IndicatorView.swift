// Indicator (design/ui/components/Indicator): the 🤫 (the Noto artwork, never a typed emoji) and a ring that says
// what shepetal is doing. Recording is a full signal ring, hands-free a signal ring with a gap at the top, writing
// an ink ring that pulses, a note no ring and a short label. The state is always named in words: the accessible
// name, the tooltip, and the label beside it where people read it.
import AppKit
import SwiftUI

struct SHIndicator: View {
    enum State: Equatable, Sendable {
        case recording, handsFree, writing
        /// A short message, eight words or fewer.
        case note(String)

        /// The state in words.
        var name: String {
            switch self {
            case .recording: "Recording"
            case .handsFree: "Hands-free"
            case .writing: "Writing"
            case .note: "A note"
            }
        }
    }

    enum Size: Sendable {
        /// sh-indicator, 18 pt, as on screen.
        case screen
        /// 44 pt, for onboarding and help pictures, always captioned.
        case large
    }

    let state: State
    var size: Size = .screen

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var dim = false
    @SwiftUI.State private var shown = false

    init(_ state: State, size: Size = .screen) {
        self.state = state
        self.size = size
    }

    private var diameter: CGFloat { size == .screen ? SH.indicator : 44 }
    private var artwork: CGFloat { size == .screen ? 12 : 28 }
    private var ringWidth: CGFloat { size == .screen ? 2 : 3 }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Image(nsImage: Self.shush).resizable().interpolation(.high).frame(width: artwork, height: artwork)
                ring
            }
            .frame(width: diameter, height: diameter)
            if case .note(let text) = state {
                Text(text)
                    .font(SHFonts.font(.ui, size: 11, weight: 560))
                    .lineSpacing(0)
                    .foregroundStyle(SH.noteText)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(SH.noteLabel, in: RoundedRectangle(cornerRadius: SH.radiusSm, style: .continuous))
                    .fixedSize()
            }
        }
        // It appears in 160 ms, 92 % to 100 % scale (sh-hush); at once under Reduce motion.
        .scaleEffect(shown || reduceMotion ? 1 : 0.92)
        .opacity(shown || reduceMotion ? 1 : 0)
        .onAppear {
            withAnimation(SH.motion(SH.easeSettle, 0.16, reduce: reduceMotion)) { shown = true }
            pulse()
        }
        .onChange(of: state) { pulse() }
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }

    private var label: String {
        if case .note(let text) = state { return "\(state.name): \(text)" }
        return state.name
    }

    @ViewBuilder private var ring: some View {
        switch state {
        case .recording:
            Circle().strokeBorder(SH.stateRecording, lineWidth: ringWidth)
        case .handsFree:
            // A 40 degree gap centred on the top (bundle.css: the ring masked from 340 to 20 degrees).
            Circle().inset(by: ringWidth / 2)
                .trim(from: 0, to: 320.0 / 360)
                .stroke(SH.stateHandsFree, style: StrokeStyle(lineWidth: ringWidth))
                .rotationEffect(.degrees(-90 + 20))
        case .writing:
            Circle().strokeBorder(SH.stateWriting, lineWidth: ringWidth)
                .opacity(dim && !reduceMotion ? 0.35 : 1)
        case .note:
            EmptyView()
        }
    }

    /// The writing ring breathes from 100 % to 35 % and back, sh-dur-pulse each way; it rests at full under
    /// Reduce motion, and stops in every other state.
    private func pulse() {
        guard state == .writing, !reduceMotion else {
            withAnimation(nil) { dim = false }
            return
        }
        withAnimation(SH.easeBreathe.animation(SH.durPulse).repeatForever(autoreverses: true)) { dim = true }
    }

    /// The Noto 🤫 (Apache 2.0), rendered from design/ui/assets/Indicator/shush.svg at 256 px.
    static let shush: NSImage = {
        guard let image = NSImage(contentsOf: SHAssets.url("shush.png")) else {
            fatalError("shepetal UI: the indicator artwork is missing (shush.png)")
        }
        return image
    }()
}
