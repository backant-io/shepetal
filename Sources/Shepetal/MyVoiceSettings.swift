import ShepetalCore
import SwiftUI

/// F38: Settings' My voice. Edits voice.json (`MyVoice`), which dictation reads each time. Save also gets the cleanup
/// model's prompt ready for the new voice, so the next dictation does not wait for it.
@MainActor
final class MyVoiceModel: ObservableObject {
    let url: URL
    private let cleanup: @MainActor () -> CleanupModel?
    @Published var preferences = ""
    @Published var samples = Array(repeating: "", count: MyVoice.maxSamples)
    @Published private(set) var saved = MyVoice.none
    @Published private(set) var message = ""
    /// The warm-up Save started, so a test can wait for it.
    private(set) var warming: Task<Void, Never>?

    init(url: URL, cleanup: @escaping @MainActor () -> CleanupModel?) {
        self.url = url
        self.cleanup = cleanup
        reload()
    }

    var draft: MyVoice { MyVoice(preferences: preferences, samples: samples) }

    func reload() {
        saved = MyVoice.load(url)
        preferences = saved.preferences
        samples = Array((saved.samples + Array(repeating: "", count: MyVoice.maxSamples)).prefix(MyVoice.maxSamples))
    }

    func save() {
        let voice = draft
        do { try voice.save(url) } catch {
            message = "My voice: \(error.localizedDescription)"
            return
        }
        message = ""
        reload()
        guard let model = cleanup() else { return }
        warming = Task.detached { _ = try? model.rewrite("Warm up.", context: .none, voice: voice) }
    }
}

struct MyVoiceSection: View {
    @StateObject private var model: MyVoiceModel

    init(url: URL, cleanup: @escaping @MainActor () -> CleanupModel?) {
        _model = StateObject(wrappedValue: MyVoiceModel(url: url, cleanup: cleanup))
    }

    var body: some View {
        SHRowGroup("My voice") {
            SHContentRow("Preferences") {
                TextField("How your text should read", text: $model.preferences,
                          prompt: Text("For example: never use exclamation marks, use contractions"), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.shField)
            }
            ForEach(0..<MyVoice.maxSamples, id: \.self) { i in
                SHContentRow("Sample \(i + 1)") {
                    TextField("Writing sample \(i + 1)", text: $model.samples[i], prompt: Text("Something you wrote yourself"), axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.shField)
                }
            }
            SHContentRow("") {
                if !model.message.isEmpty { SHErrorLine(model.message) }
            } action: {
                Button("Save", action: model.save).buttonStyle(.keycap(.secondary, .sm)).disabled(model.draft == model.saved)
            }
        } footer: {
            Text("With the cleanup model on, every dictation then goes through it, on this Mac, and is written to match: punctuation, capital letters, contractions and line breaks. It never adds, drops or swaps a word you said; when it tries, you get the text without My voice. \(MyVoice.limit) characters at most in each field. Clear every field and save to turn it off. Your style for the app still applies after it.")
        }
    }
}
