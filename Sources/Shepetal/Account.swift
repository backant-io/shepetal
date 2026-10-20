import AppKit
import ShepetalCore

/// Sign-in, the 30-day trial and the lifetime license in the running app. The license is checked at launch and
/// then every 24 h, in the background, never while a dictation runs: a dictation that starts cancels a check in
/// flight. The last good answer is cached in <data>/account.json and holds for 7 days offline.
@MainActor
final class Account: NSObject, ObservableObject {
    static let shared = Account(client: AccountClient(), tokens: .keychain(),
                                stateURL: Paths.root.appendingPathComponent("account.json"))

    @Published private(set) var access: Access = .signedOut
    /// The code shown in the browser while a sign-in waits for the user.
    @Published private(set) var pendingCode: String?
    /// The last error or progress line ("" when there is nothing to say).
    @Published private(set) var message = ""

    var email: String { state.license?.email ?? "" }
    var signedIn: Bool { token != nil }
    var signingIn: Bool { signInTask != nil }

    var now: () -> Date = Date.init
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var sleep: DeviceFlow.Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    private(set) var hint: (String) -> Void = { _ in }
    private var isDictating: () -> Bool = { false }

    private let client: AccountClient
    private let tokens: TokenStore
    private let stateURL: URL
    private(set) var state: AccountState
    private var token: String?
    private(set) var checkTask: Task<Void, Never>?
    private(set) var signInTask: Task<Void, Never>?
    private var pendingURL: URL?
    private var recheckUntil: Date?
    private var timer: Timer?

    init(client: AccountClient, tokens: TokenStore, stateURL: URL) {
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
        if let h = access.blockedHint { hint(h) }
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
        guard access.allowsDictation else {
            hint(pendingCode.map { "Finish signing in: confirm code \($0) in your browser" } ?? access.blockedHint ?? "")
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

    /// Device flow: opens the sign-in page in the browser and waits for the user to confirm there.
    @objc func signIn() {
        if signingIn {
            if let pendingURL { openURL(pendingURL) }
            return
        }
        message = "Opening your browser to sign in…"
        signInTask = Task { [client, sleep] in
            defer { signInTask = nil; pendingCode = nil; pendingURL = nil; refresh() }
            do {
                let (token, _) = try await DeviceFlow.signIn(client, open: { [weak self] start in
                    await self?.showSignInPage(start)
                }, sleep: sleep)
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

    private func showSignInPage(_ start: DeviceStart) {
        pendingCode = start.userCode
        pendingURL = start.verificationURIComplete
        message = "Confirm code \(start.userCode) in your browser"
        openURL(start.verificationURIComplete)
    }

    @objc func signOut() {
        signInTask?.cancel()
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
            } catch {
                message = "Checkout failed: \(error.localizedDescription)"
            }
        }
    }

    @objc func checkNow() { check() }

    /// One line for the menu and Home.
    var summaryLine: String {
        if let pendingCode { return "Signing in: confirm code \(pendingCode) in your browser" }
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
        case .signedOut: add(signingIn ? "Open the sign-in page again…" : AccountText.signIn + "…", #selector(signIn))
        case .trial, .expired: add(AccountText.buy + "…", #selector(buy))
        case .unchecked: add("Check license now", #selector(checkNow))
        case .lifetime: break
        }
        if signedIn { add("Sign out", #selector(signOut)) }
        if !message.isEmpty, pendingCode == nil { items.append(NSMenuItem(title: message, action: nil, keyEquivalent: "")) }
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
