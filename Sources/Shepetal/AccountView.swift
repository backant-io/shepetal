import ShepetalCore
import SwiftUI

/// The Account section on Home: trial days left, "Yours forever", or why dictation is off and how to fix it.
struct AccountSection: View {
    @ObservedObject var account = Account.shared

    var body: some View {
        Section("Account") {
            LabeledContent("License", value: account.summaryLine)
            switch account.access {
            case .signedOut:
                Button(AccountText.signIn) { account.signIn() }.disabled(account.signingIn)
            case .trial:
                Button(AccountText.buy) { account.buy() }
            case .expired:
                Button(AccountText.buy) { account.buy() }
                Button("Check license now") { account.checkNow() }
            case .unchecked:
                Button("Check license now") { account.checkNow() }
            case .lifetime:
                EmptyView()
            }
            if account.signedIn { Button("Sign out") { account.signOut() } }
            if !account.message.isEmpty, !account.signingIn {
                Text(account.message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
