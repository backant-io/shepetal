import ShepetalCore
import SwiftUI

/// The Account section at the top of Home: who is signed in and the plan (trial days left, "Yours forever", the
/// subscription's next date), or the sign-in call to action, and why dictation is off and how to fix it. Buy opens
/// the plan choice on the site; Manage subscription opens the Stripe Billing Portal.
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
            case .expired, .subscriptionEnded:
                Button(AccountText.buy) { account.buy() }
                Button("Check license now") { account.checkNow() }
            case .paymentFailed:
                Button(AccountText.manage) { account.manage() }.buttonStyle(.borderedProminent)
                Button("Check license now") { account.checkNow() }
            case .subscription:
                Button(AccountText.manage) { account.manage() }
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
