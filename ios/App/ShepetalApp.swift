import AVFoundation
import FluidAudio
import ShepetalSessionCore
import SwiftUI

@main
struct ShepetalApp: App {
    @StateObject private var session: DictationSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let mic = EngineMic()
        let session = DictationSession(mic: mic) { await AVAudioApplication.requestRecordPermission() }
        mic.onSamples = { [weak session] chunk in Task { @MainActor in session?.append(chunk) } }
        mic.onInterruption = { [weak session] in
            Task { @MainActor in await session?.stop(reason: "Recording stopped early: a call, Siri or another app took the microphone.") }
        }
        SharedHandoff.observe(SharedHandoff.stopNotification) { [weak session] in Task { await session?.stop() } }
        // Audio saved while the iPhone was locked could not be written; write it now.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak session] _ in
            Task { @MainActor in session?.flush() }
        }
        _session = StateObject(wrappedValue: session)
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("Shepetal").font(.largeTitle.bold())
                Text(session.status).multilineTextAlignment(.center)
                if let error = session.saveError { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) }
                if session.isRecording { Button("Cancel", role: .destructive) { session.cancel() } }
                Toggle("Delete recordings after 24 h", isOn: $session.deleteAfter24h)
                List(session.history) { recording in
                    VStack(alignment: .leading) {
                        Text("\(recording.date.formatted()) · \(recording.outcome.rawValue)").font(.caption).foregroundStyle(.secondary)
                        if let text = recording.text { Text(text).textSelection(.enabled) }
                        if let note = recording.note { Text(note).font(.caption) }
                    }
                }
                Text("Settings > General > Keyboard > Keyboards > Add New Keyboard > Shepetal, then turn on Allow Full Access.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Link("Donate: Buy Me a Coffee", destination: Donate.coffee)
                    Link("GitHub Sponsors", destination: Donate.sponsors)
                }
                .font(.footnote)
            }
            .padding()
            .task { await loadModel() }
            .onOpenURL { url in Task { await session.open(url) } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.sweep() }
        }
    }

    private func loadModel() async {
        guard session.transcribe == nil else { return }
        do {
            // First run downloads Parakeet TDT v3 (CoreML) into Application Support; later runs load it from disk.
            let models = try await AsrModels.downloadAndLoad()
            let manager = AsrManager()
            try await manager.loadModels(models)
            let decoderLayers = models.version.decoderLayers
            session.modelReady { samples in
                var state = TdtDecoderState.make(decoderLayers: decoderLayers)
                return try await manager.transcribe(samples, decoderState: &state).text
            }
        } catch {
            session.modelFailed(error)
        }
    }
}

/// The mic for `DictationSession`: AVAudioEngine input, resampled to 16 kHz mono Float, what Parakeet expects.
final class EngineMic: Microphone {
    var onSamples: ([Float]) -> Void = { _ in }
    /// A call, Siri or another app took the audio session. Recording does not resume on its own.
    var onInterruption: () -> Void = {}
    private let engine = AVAudioEngine()
    private var interruptions: NSObjectProtocol?

    /// False once the engine stopped itself (interruption, route or hardware change); the session's
    /// once-a-second tick then stops the recording and keeps what it has.
    var isRunning: Bool { engine.isRunning }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers]) // do not stop the user's music
        try session.setActive(true)
        let converter = AudioConverter()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let chunk = try? converter.resampleBuffer(buffer) else { return }
            self?.onSamples(chunk)
        }
        try engine.start()
        interruptions = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.onInterruption()
        }
    }

    func stop() {
        interruptions.map(NotificationCenter.default.removeObserver)
        interruptions = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
