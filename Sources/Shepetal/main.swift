import AppKit

// shepetal                           menu-bar app
// shepetal --no-permission-prompts   never asks macOS for a permission (checks only)
// shepetal --show-hint               shows the short-press hint once at launch (for screenshots)
// shepetal --e2e <wav>... [--engine fallback] [--drop-paste]   real pipeline on audio files, JSON lines out
let args = CommandLine.arguments
MainActor.assumeIsolated {
    let delegate: NSApplicationDelegate
    if let i = args.firstIndex(of: "--e2e") {
        let wavs = args[(i + 1)...].prefix { !$0.hasPrefix("--") }
        let engine = args.firstIndex(of: "--engine").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        delegate = E2E(wavs: Array(wavs), fallback: engine == "fallback", dropPaste: args.contains("--drop-paste"))
    } else {
        delegate = AppDelegate(allowPrompts: !args.contains("--no-permission-prompts"),
                               hintAtLaunch: args.contains("--show-hint"))
    }
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(delegate is E2E ? .prohibited : .accessory)  // the test never takes focus
    withExtendedLifetime(delegate) { app.run() }
}
