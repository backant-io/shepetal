import AppKit
import XCTest
import ShepetalCore
@testable import Shepetal

/// The account in the running app against a local stub server and a fake browser: the fn gate, Google sign-in
/// with PKCE, the license states,
/// sign-out, checkout, the offline grace and "never during dictation". Uses an in-memory token store and a
/// temp state file, never the Keychain item or data dir of the real app.
@MainActor
final class AccountControllerTests: XCTestCase {
    private var server: StubServer!
    private var dir: URL!
    private var tokens: TokenStore!
    private var hints: [String] = []
    private var opened: [URL] = []
    private var dictating = false
    /// The fake browser: the login URL it got, and what it answers.
    private var loginURLs: [URL] = []
    private var answer: (URLComponents) throws -> URL = { c in
        let state = c.queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "shepetal://auth?code=abc123&state=\(state)")!
    }

    private func browser(_ url: URL, _ scheme: String) async throws -> URL {
        XCTAssertEqual(scheme, "shepetal")
        loginURLs.append(url)
        return try answer(try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)))
    }

    private func query(_ url: URL?, _ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
    }
    private let day: TimeInterval = 86_400

    override func setUp() async throws {
        server = try StubServer()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-account-\(UUID().uuidString)")
        tokens = .memory()
        hints = []; opened = []; dictating = false; loginURLs = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var stateURL: URL { dir.appendingPathComponent("account.json") }

    private func account() -> Account {
        let a = Account(client: AccountClient(base: server.url), tokens: tokens, stateURL: stateURL)
        a.openURL = { [unowned self] in opened.append($0) }
        a.authenticate = { [unowned self] url, scheme in try await browser(url, scheme) }
        a.start(isDictating: { [unowned self] in dictating }, hint: { [unowned self] in hints.append($0) })
        return a
    }

    private func license(_ status: String, endsIn: TimeInterval? = nil) -> (Int, Any) {
        var body: [String: Any] = ["status": status, "email": "a@example.com"]
        body["trial_ends_at"] = endsIn.map { ISO8601DateFormatter().string(from: Date() + $0) } ?? NSNull()
        return (200, body)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), what)
    }

    private func titles(_ a: Account) -> [String] { a.menuItems().map(\.title) }

    func testBeforeThePaidLaunchFnAlwaysDictates() async throws {
        let a = Account(client: AccountClient(base: server.url), tokens: tokens, stateURL: stateURL, required: false)
        a.start(isDictating: { false }, hint: { [unowned self] in hints.append($0) })
        XCTAssertTrue(a.allowFnDown(), "signed out, but sign-in is not required yet")
        XCTAssertTrue(hints.isEmpty, "no sign-in hint at launch or on fn")
        XCTAssertEqual(titles(a), ["Not signed in", "Sign in with Google to start your free 30-day trial…"], "sign-in is still offered")

        XCTAssertFalse(Account.signInRequired(env: [:], info: [:]), "off unless the release turns it on")
        XCTAssertTrue(Account.signInRequired(env: [:], info: ["ShepetalRequiresSignIn": true]))
        XCTAssertFalse(Account.signInRequired(env: ["SHEPETAL_REQUIRE_SIGNIN": "0"], info: ["ShepetalRequiresSignIn": true]))
        XCTAssertTrue(Account.signInRequired(env: ["SHEPETAL_REQUIRE_SIGNIN": "1"], info: [:]))
    }

    func testSignedOutAtFirstLaunchBlocksFnAndSaysSignIn() async throws {
        let a = account()
        XCTAssertEqual(hints, ["Sign in with Google to start your free 30-day trial"], "the 🤫 hint at launch")
        XCTAssertFalse(a.allowFnDown())
        XCTAssertEqual(hints.last, "Sign in with Google to start your free 30-day trial")
        XCTAssertEqual(titles(a), ["Not signed in", "Sign in with Google to start your free 30-day trial…"])
        XCTAssertTrue(server.requests.isEmpty, "no network until the user signs in")
    }

    func testGoogleSignInWithPKCEStoresTheTokenThenTheTrialAllowsDictation() async throws {
        server.handler = { [unowned self] r in
            switch r.path {
            case "/api/app/token":
                // The service's side of PKCE: the verifier must hash to the challenge the browser carried.
                let challenge = query(loginURLs.last, "code_challenge")
                let ok = r.body["code"] as? String == "abc123" && r.body["redirect_uri"] as? String == "shepetal://auth"
                    && (r.body["code_verifier"] as? String).map(PKCE.challenge(for:)) == challenge
                return ok ? (200, ["access_token": "tok-1", "email": "a@example.com"]) : (400, ["error": "invalid_grant"])
            default: return license("trial", endsIn: 12 * day - 60)
            }
        }
        let a = account()
        a.signIn()
        try await until("signed in and checked") { a.access == .trial(daysLeft: 12) }
        let login = try XCTUnwrap(loginURLs.first)
        XCTAssertEqual(loginURLs.count, 1)
        XCTAssertTrue(login.absoluteString.hasPrefix(server.url.absoluteString + "/app/login?"), login.absoluteString)
        XCTAssertEqual(query(login, "redirect_uri"), "shepetal://auth")
        XCTAssertEqual(query(login, "code_challenge_method"), "S256")
        XCTAssertNil(query(login, "code_verifier"))
        XCTAssertEqual(tokens.read(), "tok-1")
        XCTAssertEqual(server.requests.map(\.path), ["/api/app/token", "/api/license"])
        XCTAssertEqual(server.requests.last?.headers["authorization"], "Bearer tok-1")
        XCTAssertTrue(a.allowFnDown())
        XCTAssertEqual(titles(a), ["Free trial: 12 days left · a@example.com",
                                   "Get Shepetal for $4.99 (lifetime, updates included)…", "Sign out"])
        XCTAssertEqual(AccountState.load(stateURL).license?.status, .trial, "the status is cached")

        // Each sign-in sends a fresh state and challenge.
        a.signOut()
        a.signIn()
        try await until("signed in again") { a.access == .trial(daysLeft: 12) }
        XCTAssertNotEqual(query(loginURLs[0], "state"), query(loginURLs[1], "state"))
        XCTAssertNotEqual(query(loginURLs[0], "code_challenge"), query(loginURLs[1], "code_challenge"))
    }

    func testACallbackWithAnotherStateIsRejected() async throws {
        answer = { _ in URL(string: "shepetal://auth?code=abc123&state=forged")! }
        server.handler = { _ in (200, ["access_token": "tok-x", "email": "x@example.com"]) }
        let a = account()
        a.signIn()
        try await until("sign-in ended") { !a.signingIn }
        XCTAssertTrue(a.message.contains("did not match"), a.message)
        XCTAssertTrue(server.requests.isEmpty, "the code is never traded")
        XCTAssertNil(tokens.read())
        XCTAssertEqual(a.access, .signedOut)
    }

    func testACancelledSheetIsNotAnError() async throws {
        answer = { _ in throw CancellationError() }
        let a = account()
        a.signIn()
        try await until("sign-in ended") { !a.signingIn }
        XCTAssertEqual(a.message, "")
        XCTAssertEqual(titles(a), ["Not signed in", "Sign in with Google to start your free 30-day trial…"])
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAStuckSheetCanBeCancelledAndSignInStartedAgain() async throws {
        answer = { _ in throw URLError(.unknown) }  // replaced below; the first sheet never answers
        let a = account()
        a.authenticate = { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)  // a browser that never reports the close
            return URL(string: "shepetal://auth?code=x&state=y")!
        }
        a.signIn()
        try await until("sheet open") { a.signingIn }
        XCTAssertEqual(titles(a), ["Signing in with Google…", "Cancel sign-in"])
        a.cancelSignIn()
        XCTAssertFalse(a.signingIn)
        XCTAssertEqual(titles(a), ["Not signed in", "Sign in with Google to start your free 30-day trial…"])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(a.message, "", "cancelling is not an error")
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testANonLocalHTTPServiceIsNeverOpened() async throws {
        let a = Account(client: AccountClient(base: URL(string: "http://evil.example")!), tokens: tokens, stateURL: stateURL)
        var called = false
        a.authenticate = { url, _ in called = true; return url }
        a.signIn()
        XCTAssertFalse(a.signingIn)
        XCTAssertFalse(called)
        XCTAssertTrue(a.message.contains("https"), a.message)
    }

    func testActiveIsYoursForever() async throws {
        try tokens.write("tok-1")
        server.handler = { [unowned self] _ in license("active") }
        let a = account()
        try await until("checked at launch") { a.access == .lifetime }
        XCTAssertTrue(a.allowFnDown())
        XCTAssertEqual(titles(a), ["Yours forever · a@example.com", "Sign out"])
    }

    func testExpiredBlocksFnAndBuyOpensCheckout() async throws {
        try tokens.write("tok-1")
        server.handler = { [unowned self] r in
            r.path == "/api/checkout" ? (200, ["url": "https://checkout.stripe.com/c/pay/cs_test_1"]) : license("expired", endsIn: -day)
        }
        let a = account()
        try await until("checked at launch") { a.access == .expired }
        XCTAssertFalse(a.allowFnDown())
        XCTAssertEqual(hints.last, "Trial ended: get Shepetal for $4.99")
        XCTAssertTrue(titles(a).contains("Get Shepetal for $4.99 (lifetime, updates included)…"))
        a.buy()
        try await until("checkout opened") { !opened.isEmpty }
        XCTAssertEqual(opened, [URL(string: "https://checkout.stripe.com/c/pay/cs_test_1")!])
        XCTAssertEqual(server.requests.last?.headers["authorization"], "Bearer tok-1")
    }

    func testAPurchaseOnTheWebsiteUnlocksOnTheNextFnPress() async throws {
        try tokens.write("tok-1")
        var status = "expired"
        server.handler = { [unowned self] _ in license(status, endsIn: -day) }
        let a = account()
        try await until("checked at launch") { a.access == .expired }
        XCTAssertTrue(titles(a).contains("Check license now"))
        status = "active"  // paid on shepetal.backant.io
        let sent = server.requests.count
        XCTAssertFalse(a.allowFnDown(), "this press is still blocked")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.requests.count, sent, "a check was tried less than a minute ago")
        a.now = { Date() + 61 }
        XCTAssertFalse(a.allowFnDown())
        try await until("the blocked press asked again") { a.access == .lifetime }
        XCTAssertTrue(a.allowFnDown(), "the next press dictates")
    }

    func testBuyRechecksUntilThePurchaseShowsUp() async throws {
        try tokens.write("tok-1")
        var status = "trial"
        server.handler = { [unowned self] r in
            r.path == "/api/checkout" ? (200, ["url": "https://checkout.stripe.com/c/pay/cs_test_2"]) : license(status, endsIn: 5 * day)
        }
        let a = account()
        try await until("checked at launch") { a.access == .trial(daysLeft: 5) }
        a.buy()
        try await until("checkout opened") { !opened.isEmpty }
        status = "active"
        a.now = { Date() + 120 }
        a.tick()  // a minute later, not 24 h
        try await until("re-checked after checkout") { a.access == .lifetime }
        XCTAssertEqual(titles(a), ["Yours forever · a@example.com", "Sign out"])
    }

    func testCheckoutWithARevokedTokenSignsOut() async throws {
        try tokens.write("tok-1")
        server.handler = { [unowned self] r in r.path == "/api/checkout" ? (401, ["error": "unauthorized"]) : license("expired", endsIn: -day) }
        let a = account()
        try await until("checked at launch") { a.access == .expired }
        a.buy()
        try await until("signed out") { a.access == .signedOut }
        XCTAssertNil(tokens.read())
        XCTAssertEqual(titles(a).prefix(2), ["Not signed in", "Sign in with Google to start your free 30-day trial…"])
    }

    func testUnauthorizedSignsOut() async throws {
        try tokens.write("tok-old")
        try AccountState(license: License(status: .active, trialEndsAt: nil, email: "a@example.com"),
                         lastGoodCheck: Date(), lastAttempt: Date()).save(stateURL(creating: true))
        server.handler = { _ in (401, ["error": "unauthorized"]) }
        let a = account()
        try await until("signed out by the 401") { a.access == .signedOut }
        XCTAssertNil(tokens.read(), "the token is dropped")
        XCTAssertFalse(a.allowFnDown())
        XCTAssertNil(AccountState.load(stateURL).license)
    }

    func testOfflineGraceKeepsACachedTrialForSevenDays() async throws {
        try tokens.write("tok-1")
        server.handler = { _ in (0, [:]) }  // the service does not answer
        let ends = Date() + 10 * day
        try AccountState(license: License(status: .trial, trialEndsAt: ends, email: "a@example.com"),
                         lastGoodCheck: Date() - 6 * day, lastAttempt: Date() - 6 * day).save(stateURL(creating: true))
        let a = account()
        try await until("the launch check failed") { a.state.lastAttempt.map { Date().timeIntervalSince($0) < 60 } ?? false }
        XCTAssertEqual(a.access, .trial(daysLeft: 10))
        XCTAssertTrue(a.allowFnDown(), "6 days offline still dictates")
        XCTAssertTrue(a.message.contains("Could not check"))

        a.now = { Date() + 1.5 * 86_400 }  // now 7.5 days since the last good check
        XCTAssertFalse(a.allowFnDown(), "past 7 days offline dictation is off")
        XCTAssertEqual(a.access, .unchecked)
        XCTAssertEqual(hints.last, "Connect to the internet so Shepetal can check your license")
    }

    func testNoLicenseCheckDuringDictation() async throws {
        try tokens.write("tok-1")
        dictating = true
        server.handler = { [unowned self] _ in license("active") }
        let a = account()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(server.requests.isEmpty, "the launch check waits while a dictation runs")
        a.tick()
        XCTAssertTrue(server.requests.isEmpty, "and so does the timer's")
        dictating = false
        a.tick()
        try await until("checked once the dictation ended") { a.access == .lifetime }

        // A dictation that starts cancels the check in flight, and its answer is dropped.
        let old = Date() - 2 * day
        try AccountState(license: License(status: .active, trialEndsAt: nil, email: "a@example.com"),
                         lastGoodCheck: old, lastAttempt: old).save(stateURL)
        let gate = DispatchSemaphore(value: 0)
        server.handler = { [unowned self] _ in gate.wait(); return license("active") }
        let b = Account(client: AccountClient(base: server.url), tokens: tokens, stateURL: stateURL)
        let sent = server.requests.count
        b.check()
        XCTAssertNotNil(b.checkTask)
        try await until("check sent") { server.requests.count == sent + 1 }
        XCTAssertTrue(b.allowFnDown())
        XCTAssertNil(b.checkTask, "fn-down cancels the check")
        gate.signal()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(b.state.lastAttempt, AccountState.load(stateURL).lastAttempt)
        XCTAssertLessThan(b.state.lastAttempt!, Date() - day, "the cancelled check's answer is not used")
    }

    func testSignOutForgetsTokenAndLicense() async throws {
        try tokens.write("tok-1")
        server.handler = { [unowned self] _ in license("active") }
        let a = account()
        try await until("checked") { a.access == .lifetime }
        a.signOut()
        XCTAssertNil(tokens.read())
        XCTAssertEqual(a.access, .signedOut)
        XCTAssertNil(AccountState.load(stateURL).license)
        XCTAssertFalse(a.allowFnDown())
    }

    func testKeychainStoreRoundTrips() throws {
        let store = TokenStore.keychain(service: "io.backant.shepetal.account.test.\(UUID().uuidString)")
        defer { store.delete() }
        XCTAssertNil(store.read())
        try store.write("tok-a")
        try store.write("tok-b")
        XCTAssertEqual(store.read(), "tok-b")
        store.delete()
        XCTAssertNil(store.read())
        let home = getenv("SHEPETAL_HOME").map { String(cString: $0) }
        defer { if let home { setenv("SHEPETAL_HOME", home, 1) } else { unsetenv("SHEPETAL_HOME") } }
        setenv("SHEPETAL_HOME", dir.path, 1)
        XCTAssertEqual(TokenStore.keychainService, "io.backant.shepetal.account.dev", "a SHEPETAL_HOME run gets its own item")
        unsetenv("SHEPETAL_HOME")
        XCTAssertEqual(TokenStore.keychainService, "io.backant.shepetal.account")
    }

    private func stateURL(creating: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return stateURL
    }
}
