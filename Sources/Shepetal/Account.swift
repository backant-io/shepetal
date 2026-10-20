import AppKit
import ShepetalCore

/// Sign-in, the 30-day trial and the lifetime license in the running app. The license is checked at launch and
/// then every 24 h, in the background, never while a dictation runs: a dictation that starts cancels a check in
/// flight. The last good answer is cached in <data>/account.json and holds for 7 days offline.
@MainActor
final class Account: NSObject, ObservableObject {
    static let shared = Account(client: AccountClient(), tokens: .keychain(),
                                stateURL: Paths.root.appendingPathComponent("account.json"), required: signInRequired())

    /// Whether dictation needs a trial or a license. It stays off until shepetal.backant.io is live, because
    /// before that nobody could sign in and dictation would be off for everyone. The release turns it on with
    /// `ShepetalRequiresSignIn` = true in Info.plist (scripts/make-app.sh). SHEPETAL_REQUIRE_SIGNIN=1 or 0
    /// overrides it for a hand test.
    static func signInRequired(env: [String: String] = ProcessInfo.processInfo.environment,
                               info: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        if let v = env["SHEPETAL_REQUIRE_SIGNIN"] { return v == "1" }
        return info?["ShepetalRequiresSignIn"] as? Bool ?? false
    }

    /// False before the paid launch: sign-in, the trial line and Buy work, but fn always dictates.
    let required: Bool

    @Published private(set) var access: Access = .signedOut
    /// The last error or progress line ("" when there is nothing to say).
    @Published private(set) var message = ""

    var email: String { state.license?.email ?? "" }
    var signedIn: Bool { token != nil }
    var signingIn: Bool { signInTask != nil }

    var now: () -> Date = Date.init
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Shows the login page and returns the shepetal:// callback (ASWebAuthenticationSession; tests fake it).
    var authenticate: (URL, String) async throws -> URL = { try await WebLogin.authenticate($0, scheme: $1) }
    private(set) var hint: (String) -> Void = { _ in }
    private var isDictating: () -> Bool = { false }

    private let client: AccountClient
    private let tokens: TokenStore
    private let stateURL: URL
    private(set) var state: AccountState
    private var token: String?
    private(set) var checkTask: Task<Void, Never>?
    private(set) var signInTask: Task<Void, Never>?
    private var signInRun = 0
    private var recheckUntil: Date?
    private var timer: Timer?

    init(client: AccountClient, tokens: TokenStore, stateURL: URL, required: Bool = true) {
        self.required = required
        self.client = client
        self.tokens = tokens
        self.stateURL = stateURL
        token = tokens.read()
        state = AccountState.load(stateURL)
        super.init()
        refresh()
    }

    /// At launch: check the license if signed in, say why dictation is off if it is, then tick every minute.
    func start(isDictating: @escaping () -> Bool, hint: @escaping (String) -> Void) {
        self.isDictating = isDictating
        self.hint = hint
        if signedIn { check() }
        // A signed-in user whose cache is stale gets the answer of the check that just started instead.
        if required, let h = access.blockedHint, access != .unchecked || !signedIn { hint(h) }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func tick() {
        refresh()
        guard signedIn else { return }
        let recheck = recheckUntil.map { now() < $0 && access != .lifetime } ?? false
        if recheck || AccountPolicy.checkDue(state: state, now: now()) { check() }
    }

    /// The fn gate, called on fn-down. False: dictation is off and the hint says why. True: the press goes on,
    /// and a license check in flight is cancelled so no request runs while the user dictates.
    func allowFnDown() -> Bool {
        refresh()
        guard access.allowsDictation || !required else {
            hint(signingIn ? "Finish signing in with Google first" : access.blockedHint ?? "")
            // Nothing is being dictated, so ask again: a purchase on the website or a network that came back
            // unlocks on the next press instead of the next day. At most once a minute.
            if signedIn, now().timeIntervalSince(state.lastAttempt ?? .distantPast) >= 60 { check() }
            return false
        }
        checkTask?.cancel()
        checkTask = nil
        return true
    }

    /// One license check in the background, unless one runs or the user is dictating.
    func check() {
        guard let token, checkTask == nil, !isDictating() else { return }
        checkTask = Task { [client] in
            let result: Result<LicenseReply, Error>
            do { result = .success(try await client.license(token: token)) } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }  // a dictation started: the next tick tries again
            checkTask = nil
            finishCheck(result)
        }
    }

    private func finishCheck(_ result: Result<LicenseReply, Error>) {
        let (s, signedOut) = AccountPolicy.apply(result, to: state, now: now())
        state = s
        save()
        if signedOut {
            tokens.delete()
            token = nil
            message = "Signed out on shepetal.backant.io. Sign in again."
        } else if case let .failure(error) = result {
            message = "Could not check the license: \(error.localizedDescription)"
        } else {
            message = ""
        }
        refresh()
    }

    /// Google sign-in with PKCE: the login page in an ASWebAuthenticationSession, the code from the
    /// shepetal://auth callback (state checked), then the code and verifier traded for the token.
    /// A cancelled sheet ends it quietly.
    @objc func signIn() {
        guard !signingIn else { return }
        let pkce = PKCE.generate()
        let url = AppLogin.loginURL(base: client.base, pkce: pkce)
        guard AccountClient.isWebPage(url) else {
            message = "Sign-in needs an https address for the account service"
            return
        }
        message = "Signing in with Google…"
        objectWillChange.send()  // Home shows Cancel sign-in
        signInRun += 1
        let run = signInRun
        signInTask = Task { [client, authenticate] in
            defer {
                if run == signInRun { signInTask = nil }  // not a newer sign-in's
                refresh()
            }
            do {
                let callback = try await authenticate(url, AppLogin.callbackScheme)
                let code = try AppLogin.code(from: callback, state: pkce.state)
                let (token, _) = try await client.exchange(code: code, verifier: pkce.verifier)
                try Task.checkCancellation()
                try tokens.write(token)
                self.token = token
                state = AccountState()
                save()
                message = ""
                refresh()
                check()
            } catch is CancellationError {
                message = ""
            } catch {
                message = "Sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    /// Closes the sign-in sheet (it may also be stuck in a browser that never reports a close).
    @objc func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        message = ""
        refresh()
    }

    @objc func signOut() {
        signInTask?.cancel()
        signInTask = nil
        checkTask?.cancel()
        checkTask = nil
        tokens.delete()
        token = nil
        state = AccountState()
        save()
        message = ""
        refresh()
    }

    /// Opens Stripe Checkout for the lifetime license, then re-checks every minute for an hour so the
    /// purchase shows up without waiting a day.
    @objc func buy() {
        guard let token else { return signIn() }
        message = "Opening checkout…"
        Task { [client] in
            do {
                openURL(try await client.checkout(token: token))
                message = ""
                recheckUntil = now().addingTimeInterval(3600)
            } catch let e as AccountError where e == .signedOut {
                signOut()  // the token was revoked: offer Sign in again
                message = "Signed out on shepetal.backant.io. Sign in again, then buy."
            } catch {
                message = "Checkout failed: \(error.localizedDescription)"
            }
        }
    }

    @objc func checkNow() { check() }

    /// One line for the menu and Home.
    var summaryLine: String {
        if signingIn { return "Signing in with Google…" }
        if !email.isEmpty, access != .signedOut { return "\(access.summary) · \(email)" }
        return access.summary
    }

    /// The account part of the 🤫 menu.
    func menuItems() -> [NSMenuItem] {
        refresh()
        var items = [NSMenuItem(title: summaryLine, action: nil, keyEquivalent: "")]
        func add(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            items.append(i)
        }
        switch access {
        case .signedOut:
            if signingIn { add("Cancel sign-in", #selector(cancelSignIn)) } else { add(AccountText.signIn + "…", #selector(signIn)) }
        case .trial: add(AccountText.buy + "…", #selector(buy))
        case .expired:
            add(AccountText.buy + "…", #selector(buy))
            add("Check license now", #selector(checkNow))  // bought on the website
        case .unchecked: add("Check license now", #selector(checkNow))
        case .lifetime: break
        }
        if signedIn { add("Sign out", #selector(signOut)) }
        if !message.isEmpty, !signingIn { items.append(NSMenuItem(title: message, action: nil, keyEquivalent: "")) }
        return items
    }

    private func refresh() {
        let a = AccountPolicy.access(signedIn: signedIn, state: state, now: now())
        if a != access { access = a }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try state.save(stateURL)
        } catch { message = "Could not save the license: \(error.localizedDescription)" }
    }
}
