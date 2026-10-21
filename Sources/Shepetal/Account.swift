import AppKit
import ShepetalCore

/// Sign-in, the 30-day trial and the lifetime license in the running app. The license is checked at launch and
/// then every 24 h, in the background, never while a dictation runs: a dictation that starts cancels a check in
/// flight. The last good answer is cached in <data>/account.json, sealed with the token: a lifetime license then
/// holds offline for good, a trial for 7 days.
@MainActor
final class Account: NSObject, ObservableObject {
    static let shared = Account(client: AccountClient(), tokens: .keychain(),
                                stateURL: Paths.root.appendingPathComponent("account.json"), required: signInRequired())

    /// Whether dictation needs a trial or a license. Release builds (`scripts/make-app.sh --zip`,
    /// `scripts/make-dmg.sh`) set `ShepetalRequiresSignIn` = true in Info.plist; a build from source does not, so
    /// it dictates without signing in. SHEPETAL_REQUIRE_SIGNIN=1 or 0 overrides it for a hand test.
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
    /// Opens the Shepetal window on Home, where Sign in is.
    private var showHome: () -> Void = {}
    private var shownHomeAtLaunch = false
    private var launchCheck = false
    /// A refused press is down: its release opens Home (`afterBlockedPress`).
    private var homeOnRelease = false

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

    /// At launch: check the license if signed in, say why dictation is off if it is and open Home (once),
    /// then tick every minute.
    func start(isDictating: @escaping () -> Bool, hint: @escaping (String) -> Void, showHome: @escaping () -> Void = {}) {
        self.isDictating = isDictating
        self.hint = hint
        self.showHome = showHome
        launchCheck = signedIn
        if signedIn { check() }
        // A signed-in user whose cache is stale gets the answer of the check that just started instead.
        if required, let h = access.blockedHint, access != .unchecked || !signedIn {
            hint(h)
            showHomeAtLaunch()
        }
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
            homeOnRelease = !signingIn  // the sign-in sheet stays in front
            // Nothing is being dictated, so ask again: a purchase on the website or a network that came back
            // unlocks on the next press instead of the next day. At most once a minute.
            if signedIn, now().timeIntervalSince(state.lastAttempt ?? .distantPast) >= 60 { check() }
            return false
        }
        homeOnRelease = false
        launchCheck = false  // the user dictates now: a later check never opens the window
        checkTask?.cancel()
        checkTask = nil
        return true
    }

    /// The key input after a refused press. Its release opens Home, where Sign in (or Buy) is, unless another key
    /// went down first: fn+Delete, fn+arrows and fn+F-keys are shortcuts, not a try at dictating, and the window
    /// would take the focus, and their next key, from the user's app on every press.
    func afterBlockedPress(_ input: KeyInput) {
        guard homeOnRelease, input == .pttUp || input == .otherKey else { return }
        homeOnRelease = false
        if input == .pttUp { showHome() }
    }

    /// One license check in the background, unless one runs or the user is dictating.
    func check() {
        guard let token, checkTask == nil, !isDictating() else { return }
        checkTask = Task { [client] in
            let result: Result<LicenseReply, Error>
            do { result = .success(try await client.license(token: token)) } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }  // a dictation started: the next tick tries again
            checkTask = nil
            finishCheck(result, sentWith: token)
        }
    }

    private func finishCheck(_ result: Result<LicenseReply, Error>, sentWith checkedToken: String) {
        let (s, signedOut) = AccountPolicy.apply(result, to: state, now: now(), token: checkedToken)
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
        if launchCheck {  // the launch check said signed out, expired or not checkable
            launchCheck = false
            showHomeAtLaunch()
        }
    }

    /// Once per launch, so the window does not keep taking the focus.
    private func showHomeAtLaunch() {
        guard required, !access.allowsDictation, !shownHomeAtLaunch else { return }
        shownHomeAtLaunch = true
        showHome()
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
            } catch let e as AccountError where e == .alreadyBought {
                message = ""
                check()  // bought already (another device, or before the re-check ran): show "Yours forever"
            } catch let e as AccountError where e == .signedOut {
                signOut()  // the token was revoked: offer Sign in again
                message = "Signed out on shepetal.backant.io. Sign in again, then buy."
            } catch {
                message = "Checkout failed: \(error.localizedDescription)"
            }
        }
    }

    @objc func checkNow() { check() }

    /// One line for Home: "Signed in as <email> · Trial, 12 days left", or "Not signed in".
    var summaryLine: String {
        if signingIn { return "Signing in with Google…" }
        guard signedIn else { return access.summary }
        return (email.isEmpty ? "Signed in" : "Signed in as \(email)") + " · " + access.summary
    }

    func refresh() {
        let a = AccountPolicy.access(token: token, state: state, now: now())
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
