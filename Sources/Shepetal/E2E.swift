import AppKit
import ShepetalCore

/// `shepetal --e2e <wav>...`: the real pipeline on audio files. Each file goes through the capture
/// resampler, the speech model, cleanup, the audio store, history, and the pasteboard + Cmd+V insertion
/// into a text view this process owns. Prints one JSON line per file.
/// It runs while people and other tests use the Mac, so it shows no window, never takes focus, and pastes
/// through a private pasteboard instead of the user's clipboard.
@MainActor
final class E2E: NSObject, NSApplicationDelegate {
    private let wavs: [String]
    private let prefer: SpeechModel?
    private var window: NSWindow!
    private var textView: PrivatePasteView!
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.backant.shepetal.e2e.\(UUID().uuidString)"))

    private let dropPaste: Bool

    /// `dropPaste` swallows the Cmd+V, as when the target lost focus, to check the clipboard hand-off.
    init(wavs: [String], fallback: Bool, dropPaste: Bool = false) {
        self.wavs = wavs
        self.dropPaste = dropPaste
        prefer = fallback ? currentModelTier().fallback : nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Cmd+V reaches the text view through an Edit > Paste key equivalent, as in any Mac app. The item
        // targets the view, so the paste needs no key window and the window is never put on screen.
        textView = PrivatePasteView(frame: NSRect(x: 0, y: 0, width: 520, height: 160))
        textView.source = pasteboard
        let edit = NSMenu(title: "Edit")
        edit.autoenablesItems = false
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v").target = textView
        let editItem = NSMenuItem()
        editItem.submenu = edit
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(editItem)

        window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = textView
        Task { exit(await run()) }
    }

    private func run() async -> Int32 {
        let t0 = ProcessInfo.processInfo.systemUptime
        defer { pasteboard.releaseGlobally() }
        let engine: SpeechEngine
        let pipeline: Pipeline
        do {
            engine = try await Speech.load(prefer: prefer)
            pipeline = try Pipeline(pasteboard: pasteboard)
        } catch {
            print(json(["error": error.localizedDescription]))
            return 1
        }
        // Names only, never contents: stop before the first insert unless it goes to this run's private pasteboard.
        guard pipeline.inserter.pasteboard.name == pasteboard.name else {
            print(json(["error": "not the private pasteboard: \(pipeline.inserter.pasteboard.name.rawValue)"]))
            return 1
        }
        let loadMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        // The app each dictation records, fixed so history can be checked against it. The page-URL lookup is a
        // slow stand-in for a browser's AX walk: resolve must return at once and run it off the main thread.
        let resolveStart = ProcessInfo.processInfo.systemUptime
        let lookup = AppContext.resolve(AppContext(name: "E2E Browser", bundleId: "com.apple.Safari"), pid: 0) { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return Thread.isMainThread ? "looked up on the main thread" : "https://user:secret@example.com:8443/e2e/page?code=abc#token"
        }
        let resolveMs = (ProcessInfo.processInfo.systemUptime - resolveStart) * 1000
        let app = await lookup.value
        var failed = false
        for wav in wavs {
            textView.string = ""
            let samples: [Float]
            do { samples = try Resampler.read(URL(fileURLWithPath: wav)) } catch {
                print(json(["wav": wav, "error": error.localizedDescription]))
                failed = true
                continue
            }
            let run = await pipeline.process(samples, engine: engine, app: app, context: { [textView] in
                FocusedText.context(FocusedText.Field(textView!))
            }, sendPaste: { event in
                // The same Cmd+V the app posts system-wide, delivered through this process's menu instead.
                guard !dropPaste, event.type == .keyDown, let e = NSEvent(cgEvent: event) else { return }
                _ = NSApp.mainMenu?.performKeyEquivalent(with: e)
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
            out["app_resolve_ms"] = Int(resolveMs)
            out["history_app"] = stored?.app ?? ""
            out["history_bundle_id"] = stored?.bundleId ?? ""
            out["history_url"] = stored?.url ?? ""
            // History's re-transcribe: the kept WAV, the same text step, the same row. The row first names
            // another model, so the check sees re-transcribe record the engine it used.
            var older = run.entry
            older.model = "e2e-older-model"
            do {
                try pipeline.history.update(older)
                _ = try await pipeline.retranscribe(older, with: engine)
            } catch { out["retranscribe_error"] = "\(error)" }
            let again = (try? pipeline.history.recent(limit: 50))?.first { $0.id == run.entry.id }
            out["retranscribed_text"] = again?.text ?? ""
            out["retranscribed_model"] = again?.model ?? ""
            out["retranscribed_row_kept"] = again != nil && again?.createdAt == stored?.createdAt
                && again?.outcome == stored?.outcome && again?.audioPath == stored?.audioPath
            out["error"] = run.error ?? ""
            out["pasteboard"] = pipeline.inserter.pasteboard.name.rawValue
            out["pasteboard_text"] = pasteboard.string(forType: .string) ?? ""
            out["window_visible"] = window.isVisible
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

/// Pastes from the test's private pasteboard, so the user's clipboard is never read or written.
final class PrivatePasteView: NSTextView {
    var source: NSPasteboard?

    override func paste(_ sender: Any?) {
        if let source { _ = readSelection(from: source) }
    }
}

extension FocusedText.Field {
    /// A text view's own accessibility answers: what TextEdit's text view gives over AX, without an AX call.
    init(_ view: NSTextView) {
        func answer(_ name: String) -> Any? {
            switch name {
            case kAXRoleAttribute: return view.accessibilityRole()?.rawValue
            case kAXValueAttribute: return view.accessibilityValue()
            case kAXNumberOfCharactersAttribute: return view.accessibilityNumberOfCharacters()
            case kAXSelectedTextAttribute: return view.accessibilitySelectedText()
            case kAXSelectedTextRangeAttribute:
                let r = view.accessibilitySelectedTextRange()
                var cf = CFRange(location: r.location, length: r.length)
                return AXValueCreate(.cfRange, &cf)
            default: return nil
            }
        }
        self.init(get: { name in answer(name).map { (.success, $0 as AnyObject) } ?? (.attributeUnsupported, nil) },
                  string: { view.accessibilityString(for: NSRange(location: $0.location, length: $0.length)) })
    }
}
