import AppKit
import AVFoundation
import ShepetalCore

/// Converts any input format to the 16 kHz mono Float32 the models take.
final class Resampler {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioStore.sampleRate),
                                      channels: 1, interleaved: false)!
    private let converter: AVAudioConverter
    var inputFormat: AVAudioFormat { converter.inputFormat }

    init?(from input: AVAudioFormat) {
        guard let c = AVAudioConverter(from: input, to: Self.format) else { return nil }
        c.downmix = true
        converter = c
    }

    /// Pass nil at the end to flush what the resampler still holds.
    func convert(_ input: AVAudioPCMBuffer?) -> [Float] {
        let ratio = Self.format.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            guard let input, !given else {
                status.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// Reads a whole audio file through the same conversion the microphone uses.
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let r = Resampler(from: file.processingFormat),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw SpeechError("Cannot convert \(url.lastPathComponent)")
        }
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buf)
            samples += r.convert(buf)
        }
        return samples + r.convert(nil)
    }
}

/// Opens the mic for each dictation (so the macOS mic indicator is on only while dictating)
/// and collects 16 kHz mono samples. Each open builds a fresh engine on the chosen device, so a device
/// or format change never reuses a stale format.
final class Recorder {
    private var engine: AVAudioEngine?
    private let queue = DispatchQueue(label: "io.backant.shepetal.mic")
    private let lock = NSLock()
    private var samples: [Float] = []
    private var resampler: Resampler?
    private var health = MicHealth(start: 0)
    private var events: [MicHealth.Event] = []
    private var observer: NSObjectProtocol?
    private(set) var device: MicDevice?
    /// Main thread: the engine stopped itself because the device or its format changed.
    var onConfigurationChange: (() -> Void)?

    static var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var isRecording: Bool { engine != nil }

    /// Starts recording from `device` (nil: the system default input).
    func start(_ device: MicDevice? = nil) throws {
        lock.withLock { samples = []; events = []; health = MicHealth(start: ProcessInfo.processInfo.systemUptime) }
        try open(device)
    }

    /// Opens the same device again, keeping what was recorded so far.
    func reopen() throws {
        let device = device
        close()
        try open(device)
    }

    func stop() -> [Float] {
        close()
        return lock.withLock { samples }
    }

    /// Health events since the last call, plus the check for buffers that never came.
    func healthEvents() -> [MicHealth.Event] {
        lock.withLock {
            defer { events = [] }
            return events + health.tick(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func open(_ device: MicDevice?) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device {
            guard var id = AudioDevices.id(forUID: device.uid), let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw SpeechError("Cannot open \(device.name)")
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError("No microphone") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in self?.take(buf) }
        engine.prepare()
        // Off the main thread, with a timeout, so a hung audio driver cannot freeze the app.
        var failure: Error?
        let started = DispatchSemaphore(value: 0)
        queue.async {
            do { try engine.start() } catch { failure = error }
            started.signal()
        }
        guard started.wait(timeout: .now() + MicHealth.openTimeout) == .success else {
            queue.async { input.removeTap(onBus: 0); engine.stop() }  // runs once the hung start returns
            throw SpeechError("\(device?.name ?? "The mic") did not open within \(Int(MicHealth.openTimeout)) s")
        }
        if let failure {
            input.removeTap(onBus: 0)
            throw failure
        }
        self.engine = engine
        self.device = device
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in self?.onConfigurationChange?() }
    }

    /// Stops the engine and moves what the resampler still holds into `samples`.
    private func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lock.withLock {
            samples += resampler?.convert(nil) ?? []
            resampler = nil
        }
    }

    private func take(_ buf: AVAudioPCMBuffer) {
        let t = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            // Built from the buffer itself, so a device whose format was reported stale is still resampled right.
            if resampler?.inputFormat != buf.format {
                samples += resampler?.convert(nil) ?? []
                resampler = Resampler(from: buf.format)
            }
            if let ch = buf.floatChannelData {
                events += health.buffer(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)), at: t)
            }
            samples += resampler?.convert(buf) ?? []
        }
    }
}

/// Picks the mic for every dictation (forced, ranked, system default; never a closed lid's built-in mic),
/// watches hot-plug and the mic's health, and builds the Microphone menu.
@MainActor
final class Mic: NSObject {
    let recorder = Recorder()
    /// Shows text next to 🤫.
    var notice: (String) -> Void = { _ in }
    /// The dictation has to end because of the mic: stop it (the audio is kept) and show `message`.
    /// `transcribe` is false when there is nothing to transcribe.
    var end: (_ transcribe: Bool, _ message: String) -> Void = { _, _ in }

    private let defaults = UserDefaults.standard
    private var notices: MicNotices
    private var timer: Timer?
    private var rebuilds = 0
    private static let maxRebuilds = 3  // format changes per dictation before giving up

    private var forced: String? {
        get { defaults.string(forKey: "micForced") }
        set { defaults.set(newValue, forKey: "micForced") }
    }
    private var ranking: [String] {
        get { defaults.stringArray(forKey: "micRanking") ?? [] }
        set { defaults.set(newValue, forKey: "micRanking") }
    }

    override init() {
        notices = MicNotices(seen: defaults.stringArray(forKey: "micSeen").map(Set.init),
                             bluetoothHintShown: defaults.bool(forKey: "micBluetoothHintShown"))
        super.init()
        recorder.onConfigurationChange = { [weak self] in MainActor.assumeIsolated { self?.configurationChanged() } }
    }

    /// Starts watching hot-plug, and notices mics plugged in since the last run.
    func watch() {
        AudioDevices.watch { [weak self] in MainActor.assumeIsolated { self?.devicesChanged() } }
        devicesChanged()
    }

    func open() throws {
        let devices = AudioDevices.inputs()
        let lidClosed = AudioDevices.lidClosed
        let pick = try MicChoice.pick(devices, forced: forced, ranking: ranking,
                                      systemDefault: AudioDevices.defaultInputUID, lidClosed: lidClosed)
        try recorder.start(pick)
        rebuilds = 0
        var lines = notices.update(devices, pick: pick)
        if let hint = notices.opening(pick, builtInUsable: !lidClosed && devices.contains { $0.transport == .builtIn }) {
            lines.append(hint)
        }
        remember(lines)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
    }

    func stop() -> [Float] {
        timer?.invalidate()
        timer = nil
        return recorder.stop()
    }

    /// A finished recording with sound but too little of it. Tune with
    /// `defaults write io.backant.shepetal micQuietFloor -float <rms>`.
    static func isQuiet(_ samples: [Float]) -> Bool {
        let knob = UserDefaults.standard.float(forKey: "micQuietFloor")
        return MicHealth.isQuiet(samples, floor: knob > 0 ? knob : MicHealth.quietFloor)
    }

    private var name: String { recorder.device?.name ?? "the mic" }

    private func checkHealth() {
        guard recorder.isRecording else { return }
        for event in recorder.healthEvents() {
            switch event {
            case .reopen:
                do { try recorder.reopen() } catch { stopDictation(transcribe: true, "Mic: \(error.localizedDescription)") }
            case .silent: notice("No sound from \(name). Is it muted?")
            case .stillSilent: notice("Still no sound from \(name). Pick another mic in the 🤫 menu.")
            case .noAudio: stopDictation(transcribe: false, "\(name.prefix(1).uppercased() + name.dropFirst()) sent no audio")
            }
        }
    }

    private func stopDictation(transcribe: Bool, _ message: String) {
        guard recorder.isRecording else { return }
        end(transcribe, message)
    }

    private func devicesChanged() {
        let devices = AudioDevices.inputs()
        if let active = recorder.device, recorder.isRecording, !devices.contains(where: { $0.uid == active.uid }) {
            stopDictation(transcribe: true, "Mic disconnected")
        }
        let pick = try? MicChoice.pick(devices, forced: forced, ranking: ranking,
                                       systemDefault: AudioDevices.defaultInputUID, lidClosed: AudioDevices.lidClosed)
        remember(notices.update(devices, pick: pick))
    }

    /// The engine stopped itself: the device went away, or its format changed (Bluetooth switching to its
    /// headset profile does that), which needs a new engine.
    private func configurationChanged() {
        guard recorder.isRecording, let device = recorder.device else { return }
        guard AudioDevices.inputs().contains(where: { $0.uid == device.uid }) else {
            return stopDictation(transcribe: true, "Mic disconnected")
        }
        rebuilds += 1
        do {
            guard rebuilds <= Self.maxRebuilds else { throw SpeechError("\(device.name) keeps changing its format") }
            try recorder.reopen()
        } catch {
            stopDictation(transcribe: true, "Mic stopped: \(error.localizedDescription)")
        }
    }

    private func remember(_ lines: [String]) {
        defaults.set(Array(notices.seen ?? []), forKey: "micSeen")
        defaults.set(notices.bluetoothHintShown, forKey: "micBluetoothHintShown")
        if !lines.isEmpty { notice(lines.joined(separator: " · ")) }
    }

    // MARK: menu

    /// Automatic, each device (to force it), and "Prefer <name>" (moves it to the top of the ranking).
    func menuItem() -> NSMenuItem {
        let devices = AudioDevices.inputs()
        let lidClosed = AudioDevices.lidClosed
        let pick = try? MicChoice.pick(devices, forced: forced, ranking: ranking,
                                       systemDefault: AudioDevices.defaultInputUID, lidClosed: lidClosed)
        let menu = NSMenu()
        let auto = menu.addItem(withTitle: "Automatic" + (pick.map { " (\($0.name))" } ?? ""), action: #selector(automatic), keyEquivalent: "")
        auto.target = self
        auto.state = forced == nil ? .on : .off
        for d in devices {
            let covered = lidClosed && d.transport == .builtIn
            let i = menu.addItem(withTitle: d.name + (covered ? " (lid closed)" : ""), action: #selector(force(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = d.uid
            i.state = forced == d.uid ? .on : .off
            i.isEnabled = !covered
        }
        menu.addItem(.separator())
        for d in devices {
            let i = menu.addItem(withTitle: "Prefer \(d.name)", action: #selector(prefer(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = d.uid
            i.state = ranking.first == d.uid ? .on : .off
        }
        let item = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func automatic() { forced = nil }
    @objc private func force(_ sender: NSMenuItem) { forced = sender.representedObject as? String }
    @objc private func prefer(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String { ranking = MicChoice.prefer(uid, in: ranking) }
    }
}
