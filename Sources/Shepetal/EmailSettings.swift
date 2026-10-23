import ShepetalCore
import SwiftUI

/// Settings' Email (F36): the signature that follows a spoken sign-off without a name. Empty, the default, adds nothing.
struct EmailSection: View {
    @AppStorage(EmailFormat.signatureKey) private var signature = ""

    var body: some View {
        SHRowGroup("Email") {
            SHContentRow("Signature") {
                TextField("Signature", text: $signature, prompt: Text("Your name"), axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.shField)
            }
        } footer: {
            Text("In mail apps and webmail, a greeting gets its own line and a sign-off such as “Best regards” its own paragraph, with the name below it. When you say a sign-off without a name, this signature goes under it. The body is not split into paragraphs, and apps set to Raw are left as said.")
        }
    }
}
