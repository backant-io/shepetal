import SwiftUI

/// F118's card: fixed colors, so it looks the same in Light and Dark appearance and wherever it is pasted. It has its
/// own file so AppearanceTests exempts only it: the sheet and Home's section around it follow the system appearance.
struct ShareCardView: View {
    let stats: ShareStats

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("🤫").font(.system(size: 26))
                Text("shepetal").font(.system(size: 26, weight: .semibold, design: .rounded))
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 44) {
                figure(stats.words.formatted(), "words dictated")
                figure("\(stats.wpm)", "words per minute")
                if stats.streak > 0 { figure("\(stats.streak)", "day streak") }
            }
            Spacer()
            Text("Voice dictation that never leaves your Mac").font(.system(size: 15)).opacity(0.55)
        }
        .padding(40)
        .frame(width: ShareCard.size.width, height: ShareCard.size.height, alignment: .leading)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.11), Color(red: 0.16, green: 0.12, blue: 0.27)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 15, weight: .medium)).opacity(0.6)
        }
    }
}
