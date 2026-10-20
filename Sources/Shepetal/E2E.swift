import AppKit
import ShepetalCore

/// `shepetal --e2e <wav>...`: the real pipeline on audio files. Each file goes through the capture
/// resampler, the speech model, cleanup, the audio store, history, and the clipboard + Cmd+V insertion
/// into a text view this process owns. Prints one JSON line per file.
@MainActor
final class E2E: NSObject, NSApplicationDelegate {
    private let wavs: [String]
    private let prefer: SpeechModel?
    private var window: NSWindow!
    private var textView: NSTextView!

    init(wavs: [String], fallback: Bool) {
        self.wavs = wavs
        prefer = fallback ? currentModelTier().fallback : nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Cmd+V reaches the text view through Edit > Paste, as in any Mac app.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(editItem)

        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 160), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.title = "Shepetal end-to-end"
        textView = NSTextView(frame: window.contentLayoutRect)
        window.contentView = textView
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        Task { exit(await run()) }
    }

    private func run() async -> Int32 {
        let t0 = ProcessInfo.processInfo.systemUptime
        let engine: SpeechEngine
        let pipeline: Pipeline
        do {
            engine = try await Speech.load(prefer: prefer)
            pipeline = try Pipeline()
        } catch {
            print(json(["error": error.localizedDescription]))
            return 1
        }
        let loadMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        var failed = false
        for wav in wavs {
            textView.string = ""
            let samples: [Float]
            do { samples = try Resampler.read(URL(fileURLWithPath: wav)) } catch {
                print(json(["wav": wav, "error": error.localizedDescription]))
                failed = true
                continue
            }
            let run = await pipeline.process(samples, engine: engine, app: AppContext.capture(), context: { [textView] in
                FocusedText.split(textView!.string, textView!.selectedRange())
            }, sendPaste: { event in
                // In-process delivery of the same Cmd+V event the app posts to the system.
                if let e = NSEvent(cgEvent: event) { NSApp.sendEvent(e) }
            })
            let stored = (try? pipeline.history.recent(limit: 50))?.first { $0.id == run.entry.id }
            let dir = Paths.audio.path
            failed = failed || run.error != nil
            var out: [String: Any] = ["wav": wav, "model": engine.name, "load_ms": Int(loadMs)]
            out["audio_seconds"] = Double(samples.count) / Double(AudioStore.sampleRate)
            out["ready_ms"] = Int(run.readyMs)
            out["raw_text"] = run.entry.rawText
            out["text"] = run.entry.text
            out["inserted_text"] = textView.string
            out["paste_landed"] = run.paste?.landed ?? false
            out["clipboard_restored"] = run.paste?.restored ?? false
            out["audio_path"] = run.entry.audioPath
            out["audio_mode"] = Self.mode(run.entry.audioPath)
            out["audio_dir_mode"] = Self.mode(dir)
            out["history_outcome"] = stored?.outcome.rawValue ?? "missing"
            out["history_audio_path"] = stored?.audioPath ?? ""
            out["history_app"] = stored?.app ?? ""
            // History's re-transcribe: the kept WAV, the same text step, the same row.
            do { _ = try await pipeline.retranscribe(run.entry, with: engine) } catch { out["retranscribe_error"] = "\(error)" }
            let again = (try? pipeline.history.recent(limit: 50))?.first { $0.id == run.entry.id }
            out["retranscribed_text"] = again?.text ?? ""
            out["retranscribed_row_kept"] = again != nil && again?.createdAt == stored?.createdAt
                && again?.outcome == stored?.outcome && again?.audioPath == stored?.audioPath
            out["error"] = run.error ?? ""
            print(json(out))
        }
        return failed ? 1 : 0
    }

    private static func mode(_ path: String) -> String {
        let n = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return String(n, radix: 8)
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
