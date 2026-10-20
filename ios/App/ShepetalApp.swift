import AVFoundation
import FluidAudio
import ShepetalSessionCore
import SwiftUI

@main
struct ShepetalApp: App {
    @StateObject private var dictation = Dictation()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("Shepetal").font(.largeTitle.bold())
                Text(dictation.status).multilineTextAlignment(.center)
                Text("Settings > General > Keyboard > Keyboards > Add New Keyboard > Shepetal, then turn on Allow Full Access.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
            .task { await dictation.prepare() }
            .onOpenURL { url in
                // shepetal://dictate?id=<UUID>, opened by the keyboard
                guard url.host == "dictate",
                      let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                          .queryItems?.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:))
                else { return }
                Task { await dictation.start(id) }
            }
        }
    }
}

/// Records in the containing app (keyboard extensions get no microphone) and transcribes on device.
@MainActor
final class Dictation: ObservableObject {
    @Published var status = "Loading speech model..."
    private let engine = AVAudioEngine()
    private var asr: AsrManager?
    private var decoderLayers = 2
    private var samples: [Float] = []
    private var sessionID: UUID?

    init() {
        SharedHandoff.observe(SharedHandoff.stopNotification) { [weak self] in
            Task { await self?.stop() }
        }
    }

    func prepare() async {
        guard asr == nil else { return }
        do {
            // First run downloads Parakeet TDT v3 (CoreML) into Application Support; later runs load it from disk.
            let models = try await AsrModels.downloadAndLoad()
            let manager = AsrManager()
            try await manager.loadModels(models)
            decoderLayers = models.version.decoderLayers
            asr = manager
            status = "Ready. Tap the mic on the Shepetal keyboard."
        } catch {
            status = "Model load failed: \(error.localizedDescription)"
        }
    }

    func start(_ id: UUID) async {
        guard await AVAudioApplication.requestRecordPermission() else {
            status = "Microphone access denied. Enable it in Settings > Shepetal."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers]) // do not stop the user's music
            try session.setActive(true)
            samples = []
            let converter = AudioConverter() // resamples to 16 kHz mono Float, what Parakeet expects
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                guard let chunk = try? converter.resampleBuffer(buffer) else { return }
                Task { @MainActor in self?.samples += chunk }
            }
            try engine.start()
            guard SharedHandoff.update({ $0.startRecording(id) }) else {
                stopEngine()
                status = "That dictation request expired. Tap the mic again."
                return
            }
            sessionID = id
            status = "Listening. Go back to your app and tap the mic to finish."
        } catch {
            stopEngine()
            status = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard let id = sessionID else { return }
        sessionID = nil
        stopEngine()
        guard SharedHandoff.update({ $0.finishRecording(id) }) else { return }
        guard let asr else {
            status = "Speech model is not loaded yet."
            return
        }
        status = "Transcribing..."
        do {
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            let text = try await asr.transcribe(samples, decoderState: &state).text
            SharedHandoff.update { $0.deliver(id, text: text) }
            SharedHandoff.post(SharedHandoff.readyNotification)
            status = "Ready. Tap the mic on the Shepetal keyboard."
        } catch {
            status = "Transcription failed: \(error.localizedDescription)"
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
