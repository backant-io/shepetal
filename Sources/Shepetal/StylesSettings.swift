import ShepetalCore
import SwiftUI

/// Settings' Styles (F37): one picker per kind of app, each with an example of what the pick does.
struct StylesSection: View {
    var body: some View {
        Section {
            ForEach(AppCategory.allCases, id: \.self) { StylePicker(category: $0) }
        } header: {
            Text("Styles")
        } footer: {
            Text("Work messages: Slack and Teams. Email: Mail, Outlook, Superhuman, Spark, and Gmail or Outlook on the web. Personal messages: Messages, WhatsApp, Telegram, Signal, WeChat and Messenger. Until you pick a style, shepetal writes Formal everywhere. Dictionary words keep their spelling in every style.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StylePicker: View {
    let category: AppCategory
    @AppStorage private var style: Style

    init(category: AppCategory) {
        self.category = category
        _style = AppStorage(wrappedValue: .formal, Styles.key(category))
    }

    var body: some View {
        Picker(category.title, selection: $style) {
            ForEach(Style.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Text(Styles.apply(style, to: category.example)).font(.caption).foregroundStyle(.secondary)
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
