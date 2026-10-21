import AppKit
import AuthenticationServices
import ShepetalCore

/// Opens the Google sign-in page in an ASWebAuthenticationSession and returns the shepetal:// callback.
/// The session shares the browser's cookies (not ephemeral), so a Google login already in the browser is
/// reused. A cancelled sheet throws CancellationError.
@MainActor
final class WebLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var anchor: NSWindow?

    static func authenticate(_ url: URL, scheme: String) async throws -> URL {
        try await WebLogin().run(url, scheme: scheme)
    }

    func run(_ url: URL, scheme: String) async throws -> URL {
        defer { anchor?.orderOut(nil); anchor = nil; session = nil }
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<URL, Error>) in
                once.continuation = done
                let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                    if let callback { return once.resume(.success(callback)) }
                    if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                        return once.resume(.failure(CancellationError()))
                    }
                    if let error { NSLog("shepetal: sign-in sheet: %@", String(describing: error)) }
                    once.resume(.failure(AccountError("The sign-in window could not open. Try again.")))
                }
                s.presentationContextProvider = self
                s.prefersEphemeralWebBrowserSession = false
                session = s
                once.setCancel { [weak s] in s?.cancel() }
                // A menu-bar app (LSUIElement) has no window of its own and is not active: activate it for this
                // user-started sign-in so the sheet comes to the front.
                NSApp.activate(ignoringOtherApps: true)
                // When start() fails the completion handler may fire as well: Once resumes only the first time.
                if !s.start() { once.resume(.failure(AccountError("The sign-in window could not open. Try again."))) }
            }
        } onCancel: {
            once.cancelSession()  // Cancel sign-in or Sign out: closes the sheet, which reports canceledLogin
        }
    }

    /// A menu-bar app has no window to attach the sheet to: use the key window (the Shepetal window when
    /// it is open), or a small transparent window in the middle of the main display.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            if let anchor { return anchor }
            if let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.title == "shepetal" }) { return w }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            w.center()
            w.orderFrontRegardless()
            anchor = w
            return w
        }
    }
}

/// Resumes the continuation exactly once, from whichever of the completion handler, a failed start() or a
/// cancel comes first, on any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    var continuation: CheckedContinuation<URL, Error>?
    private var cancel: (@MainActor () -> Void)?

    func setCancel(_ f: @escaping @MainActor () -> Void) { lock.withLock { cancel = f } }

    func resume(_ result: Result<URL, Error>) {
        lock.lock()
        let c = resumed ? nil : continuation
        resumed = true
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }

    func cancelSession() {
        let cancel = lock.withLock { self.cancel }
        DispatchQueue.main.async { MainActor.assumeIsolated { cancel?() } }
        resume(.failure(CancellationError()))
    }
}
