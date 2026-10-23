import ShepetalCore
import SwiftUI

/// Settings' Styles (F37): one picker per kind of app, each with an example of what the pick does.
struct StylesSection: View {
    var body: some View {
        SHRowGroup("Styles") {
            ForEach(AppCategory.allCases, id: \.self) { StylePicker(category: $0) }
        } footer: {
            Text("Work messages: team chat apps. Email: mail apps and webmail. Personal messages: messaging apps. Until you pick a style, shepetal writes Formal everywhere. Dictionary words keep their spelling in every style.")
        }
    }
}

/// One kind of app: its name, what the pick does to an example line, and the four styles.
private struct StylePicker: View {
    let category: AppCategory
    @AppStorage private var style: Style

    init(category: AppCategory) {
        self.category = category
        _style = AppStorage(wrappedValue: .formal, Styles.key(category))
    }

    var body: some View {
        SHContentRow(category.title) {
            Text(Styles.apply(style, to: category.example)).shText(SH.appBody).foregroundStyle(SH.text)
                .fixedSize(horizontal: false, vertical: true)
        } action: {
            SHSegmented(category.title, selection: $style, options: Style.allCases.map { ($0, $0.title) })
        }
    }
}

extension AppCategory {
    var title: String {
        switch self {
        case .work: "Work messages"
        case .personal: "Personal messages"
        case .email: "Email"
        case .other: "Other apps"
        }
    }

    /// What the picker's example shows, in Formal. The picked style is applied to it.
    var example: String {
        switch self {
        case .work: "Hey Sam, the new build is up. I will look at it after lunch."
        case .personal: "Oh, that sounds lovely. I can bring the salad on Saturday."
        case .email: "Hi Maria, thanks for the quick reply. I will send the signed copy tomorrow."
        case .other: "Well, the draft is done. I will share it on Monday."
        }
    }
}

extension Style {
    var title: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        case .excited: "Excited"
        }
    }
}
