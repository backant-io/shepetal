import SwiftUI

/// F118's card: fixed colors, so it looks the same in Light and Dark appearance and wherever it is pasted. It has its
/// own file so AppearanceTests exempts only it: the sheet and Home's section around it follow the system appearance.
/// It is the Night ground of shepetal UI whatever the system says: concrete type on ink, the Noto 🤫 artwork and the
/// wordmark in Bodoni Moda italic, the figures in Archivo and their names in Fragment Mono. Nothing on it is live, so
/// nothing is orange.
struct ShareCardView: View {
    let stats: ShareStats

    private static let ground = Color.sh(SH.bg.dark)
    private static let ink = Color.sh(SH.text.dark)
    private static let muted = Color.sh(SH.textMuted.dark)
    private static let rule = Color.sh(SH.border.dark)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: SHIndicator.shush).resizable().interpolation(.high).frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text("shepetal").font(SH.wordmark.with(size: 30).font).tracking(SH.wordmark.tracking * 30)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 44) {
                figure(stats.words.formatted(), "words dictated")
                figure("\(stats.wpm)", "words per minute")
                if stats.streak > 0 { figure("\(stats.streak)", "day streak") }
            }
            Spacer()
            Text("Write at the speed of thought.")
                .font(SH.appBody.with(size: 15).font)
                .foregroundStyle(Self.muted)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Self.rule).frame(height: 1) }
        }
        .padding(40)
        .frame(width: ShareCard.size.width, height: ShareCard.size.height, alignment: .leading)
        .foregroundStyle(Self.ink)
        .background(Self.ground)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(SHFonts.font(.ui, size: 52, weight: 560)).tracking(-0.02 * 52)
            Text(label).font(SHFonts.font(.mono, size: 13)).foregroundStyle(Self.muted)
        }
    }
}
