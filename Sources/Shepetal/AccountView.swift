import ShepetalCore
import SwiftUI

/// The Account section at the top of Home: who is signed in and the trial days left or "Yours forever", or the
/// sign-in call to action, and why dictation is off and how to fix it.
struct AccountSection: View {
    @ObservedObject var account = Account.shared

    var body: some View {
        Section("Account") {
            Text(account.summaryLine).font(.headline)
            switch account.access {
            case .signedOut:
                if account.signingIn {
                    Button("Cancel sign-in") { account.cancelSignIn() }
                } else {
                    Button(AccountText.signIn) { account.signIn() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
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
