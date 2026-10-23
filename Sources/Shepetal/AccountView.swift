import ShepetalCore
import SwiftUI

/// The Account section at the top of Home: who is signed in and the plan (trial days left, "Yours forever", the
/// subscription's next date), or the sign-in call to action, and why dictation is off and how to fix it. Buy opens
/// the plan choice on the site; Manage subscription opens the Stripe Billing Portal.
struct AccountSection: View {
    @ObservedObject var account = Account.shared

    var body: some View {
        SHRowGroup("Account") {
            SHContentRow("Plan") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.summaryLine).shText(SH.appStrong).foregroundStyle(SH.text)
                    if !account.message.isEmpty, !account.signingIn {
                        Text(account.message).shText(SH.appSmall).foregroundStyle(SH.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } action: {
                HStack(spacing: SH.space2) {
                    actions
                    if account.signedIn { Button("Sign out") { account.signOut() }.buttonStyle(.keycap(.quiet, .sm)) }
                }
            }
        }
    }

    /// The plan's actions: Sign in is the view's one primary keycap while signed out, Manage subscription while a
    /// payment failed; every other action is a secondary cap.
    @ViewBuilder private var actions: some View {
        switch account.access {
        case .signedOut:
            if account.signingIn {
                Button("Cancel sign-in") { account.cancelSignIn() }.buttonStyle(.keycap(.secondary, .sm))
            } else {
                Button(AccountText.signIn) { account.signIn() }.buttonStyle(.keycap(.primary))
            }
        case .trial:
            Button(AccountText.buy) { account.buy() }.buttonStyle(.keycap(.secondary, .sm))
        case .expired, .subscriptionEnded:
            Button(AccountText.buy) { account.buy() }.buttonStyle(.keycap(.secondary, .sm))
            Button("Check license now") { account.checkNow() }.buttonStyle(.keycap(.secondary, .sm))
        case .paymentFailed:
            Button(AccountText.manage) { account.manage() }.buttonStyle(.keycap(.primary, .sm))
            Button("Check license now") { account.checkNow() }.buttonStyle(.keycap(.secondary, .sm))
        case .subscription:
            Button(AccountText.manage) { account.manage() }.buttonStyle(.keycap(.secondary, .sm))
        case .unchecked:
            Button("Check license now") { account.checkNow() }.buttonStyle(.keycap(.secondary, .sm))
        case .lifetime:
            EmptyView()
        }
    }
}
