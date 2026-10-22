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
    /// How often the injected window presenter opened Home.
    private var homeShown = 0
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
        hints = []; opened = []; homeShown = 0; dictating = false; loginURLs = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var stateURL: URL { dir.appendingPathComponent("account.json") }

    private func account() -> Account {
        let a = Account(client: AccountClient(base: server.url), tokens: tokens, stateURL: stateURL)
        a.openURL = { [unowned self] in opened.append($0) }
        a.authenticate = { [unowned self] url, scheme in try await browser(url, scheme) }
        a.start(isDictating: { [unowned self] in dictating }, hint: { [unowned self] in hints.append($0) },
                showHome: { [unowned self] in homeShown += 1 })
        return a
    }

    private func license(_ status: String, endsIn: TimeInterval? = nil) -> (Int, Any) {
        var body: [String: Any] = ["status": status, "email": "a@example.com"]
        body["trial_ends_at"] = endsIn.map { ISO8601DateFormatter().string(from: Date() + $0) } ?? NSNull()
        return (200, body)
    }

    /// GET /api/license for the monthly plan (web/API.md), paid through `paidThrough`.
    private func monthly(_ paidThrough: Date, status: String = "active", renews: Bool = true, failed: Bool = false) -> (Int, Any) {
        (200, ["status": status, "plan": "subscription", "email": "a@example.com",
               "trial_ends_at": status == "active" ? NSNull() as Any : ISO8601DateFormatter().string(from: Date() - 40 * day) as Any,
               "paid_through": ISO8601DateFormatter().string(from: paidThrough), "renews": renews, "payment_failed": failed])
    }
    private var plans: URL { URL(string: server.url.absoluteString + "/account#plans")! }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), what)
    }

    /// The account line on Home, then the account items of the 🤫 menu.
    private func titles(_ a: Account) -> [String] {
        a.refresh()
        return [a.summaryLine] + MenuModel.account(a.access, signingIn: a.signingIn).map(\.title)
    }

    /// Presses `keys` and releases them in reverse through the real KeyRouter, and hands its inputs to the
    /// account the way App.key(_:at:) does: afterBlockedPress first, then the gate on pttDown and toggle.
    private func press(_ keys: [Int], _ a: Account) {
        var router = KeyRouter()
        var inputs: [KeyInput] = []
        for k in keys { inputs += router.key(k, down: true, active: false, canSwallow: true).inputs }
        for k in keys.reversed() { inputs += router.key(k, down: false, active: false, canSwallow: true).inputs }
        for i in inputs {
            a.afterBlockedPress(i)
            if i == .pttDown || i == .toggle { XCTAssertFalse(a.allowFnDown()) }
        }
    }

    func testBeforeThePaidLaunchFnAlwaysDictates() async throws {
        let a = Account(client: AccountClient(base: server.url), tokens: tokens, stateURL: stateURL, required: false)
        a.start(isDictating: { false }, hint: { [unowned self] in hints.append($0) }, showHome: { [unowned self] in homeShown += 1 })
        XCTAssertTrue(a.allowFnDown(), "signed out, but sign-in is not required yet")
        XCTAssertTrue(hints.isEmpty, "no sign-in hint at launch or on fn")
        XCTAssertEqual(homeShown, 0, "a build from source never opens the window by itself")
        try tokens.write("tok-1")  // signed in, and the trial ended
        server.handler = { [unowned self] _ in license("expired", endsIn: -day) }
        let b = Account(client: AccountClient(base: server.url), tokens: tokens, stateURL: stateURL, required: false)
        b.start(isDictating: { false }, hint: { [unowned self] in hints.append($0) }, showHome: { [unowned self] in homeShown += 1 })
        try await until("checked at launch") { b.access == .expired }
        XCTAssertTrue(b.allowFnDown())
        XCTAssertEqual(homeShown, 0, "nor after its launch check")
        XCTAssertEqual(titles(a), ["Not signed in", "Sign in to start your free trial…"], "sign-in is still offered")

        XCTAssertFalse(Account.signInRequired(env: [:], info: [:]), "off unless the release turns it on")
        XCTAssertTrue(Account.signInRequired(env: [:], info: ["ShepetalRequiresSignIn": true]))
        XCTAssertFalse(Account.signInRequired(env: ["SHEPETAL_REQUIRE_SIGNIN": "0"], info: ["ShepetalRequiresSignIn": true]))
        XCTAssertTrue(Account.signInRequired(env: ["SHEPETAL_REQUIRE_SIGNIN": "1"], info: [:]))
    }

    /// Pavel's retest: signed out, the app must ask for Google sign-in by itself, and fn must not open the mic.
    func testSignedOutAtFirstLaunchOpensHomeOnceBlocksFnAndSaysSignIn() async throws {
        let a = account()
        XCTAssertEqual(hints, ["Sign in with Google to start your free 30-day trial"], "the 🤫 hint at launch")
        XCTAssertEqual(homeShown, 1, "Home with Sign in opens at launch")
        a.now = { Date() + 3600 }
        a.tick()
        XCTAssertEqual(homeShown, 1, "only once per launch: the timer never takes the focus again")
        XCTAssertFalse(a.allowFnDown(), "fn is refused before the mic opens")
        XCTAssertEqual(hints.last, "Sign in with Google to start your free 30-day trial")
        XCTAssertEqual(homeShown, 1, "not on the press: fn may be the start of a shortcut")
        a.afterBlockedPress(.pttUp)
        XCTAssertEqual(homeShown, 2, "its release opens Home, where Sign in is")
        a.afterBlockedPress(.pttUp)
        XCTAssertEqual(homeShown, 2, "once per press")
        XCTAssertEqual(titles(a), ["Not signed in", "Sign in to start your free trial…"])
        XCTAssertTrue(server.requests.isEmpty, "no network until the user signs in")
    }

    func testFnDuringSignInDoesNotCoverTheSheet() async throws {
        let a = account()
        a.authenticate = { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000); throw CancellationError() }
        a.signIn()
        let shown = homeShown
        XCTAssertFalse(a.allowFnDown())
        a.afterBlockedPress(.pttUp)
        XCTAssertEqual(hints.last, "Finish signing in with Google first")
        XCTAssertEqual(homeShown, shown, "the window must not come in front of the sign-in sheet")
        a.cancelSignIn()
    }

    /// Signed out, fn+Delete, fn+arrows and fn+F-keys still reach the user's app: Home opening on them would take
    /// the focus, and the shortcut's next key, every time. Holding fn alone, or fn+Space, asks for dictation.
    func testFnShortcutsWhileSignedOutNeverOpenTheWindow() async throws {
        let a = account()
        let atLaunch = homeShown
        for keys in [[Key.fn, Key.delete], [Key.fn, Key.left], [Key.fn, 122], [Key.fn, Key.delete]] {  // 122 is F1
            press(keys, a)
        }
        XCTAssertEqual(homeShown, atLaunch, "a shortcut with fn never opens Home")
        press([Key.fn], a)
        XCTAssertEqual(homeShown, atLaunch + 1, "holding fn and letting go opens Home")
        press([Key.fn, Key.space], a)
        XCTAssertEqual(homeShown, atLaunch + 2, "so does fn+Space, the hands-free shortcut")
    }

    /// A press that dictates while the launch check runs cancels it: a later check is not the launch check, and
    /// must not open the window in the middle of the session (reviewer probe at badf1a0: it did, hours later).
    func testACancelledLaunchCheckNeverOpensTheWindowLater() async throws {
        try tokens.write("tok-1")
        try AccountState(license: License(status: .trial, trialEndsAt: Date() + 5 * day, email: "a@example.com"),
                         lastGoodCheck: Date(), lastAttempt: Date()).sealed(with: "tok-1").save(stateURL(creating: true))
        let gate = DispatchSemaphore(value: 0)
        server.handler = { [unowned self] _ in gate.wait(); return license("trial", endsIn: 5 * day) }
        let a = account()
        try await until("launch check sent") { server.requests.count == 1 }
        XCTAssertTrue(a.allowFnDown(), "the cached trial dictates")
        XCTAssertNil(a.checkTask, "and the launch check is cancelled")
        server.handler = { [unowned self] _ in license("expired", endsIn: -day) }
        gate.signal()
        a.now = { [day] in Date() + 1.1 * day }
        a.tick()
        try await until("the daily check saw it") { a.access == .expired }
        XCTAssertEqual(homeShown, 0, "only a fn press opens Home now, not the timer")
    }

    func testHomeOpensOnceWhenTheLaunchCheckSaysExpired() async throws {
        try tokens.write("tok-1")
        server.handler = { [unowned self] _ in license("expired", endsIn: -day) }
        let a = account()
        XCTAssertEqual(homeShown, 0, "nothing known yet: wait for the launch check")
        try await until("checked at launch") { a.access == .expired }
        XCTAssertEqual(homeShown, 1, "the trial ended: Home opens with Buy")
        a.now = { [day] in Date() + 2 * day }
        a.tick()
        try await until("checked again") { server.requests.count == 2 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(homeShown, 1, "a later check never opens it again")

        // Next launch: the cached answer already says expired, and the launch check agrees. Still once.
        homeShown = 0
        let b = account()
        XCTAssertEqual(homeShown, 1, "known at launch: Home opens right away")
        try await until("checked at the next launch") { server.requests.count == 3 && b.checkTask == nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(homeShown, 1, "the launch check does not open it a second time")
    }

    func testATrialNeverOpensTheWindow() async throws {
        try tokens.write("tok-1")
        try AccountState(license: License(status: .trial, trialEndsAt: Date() + 5 * day, email: "a@example.com"),
                         lastGoodCheck: Date(), lastAttempt: Date()).sealed(with: "tok-1").save(stateURL(creating: true))
        server.handler = { [unowned self] _ in license("trial", endsIn: 5 * day) }
        let a = account()
        try await until("checked at launch") { !server.requests.isEmpty && a.checkTask == nil }
        XCTAssertTrue(a.allowFnDown())
        XCTAssertEqual(homeShown, 0)
        XCTAssertTrue(hints.isEmpty)
        XCTAssertEqual(a.summaryLine, "Signed in as a@example.com · Trial, 5 days left", "Home says who is signed in")

        // The trial ends while the app runs: only the startup opens the window, a fn press does the rest.
        server.handler = { [unowned self] _ in license("expired", endsIn: -day) }
        a.now = { [day] in Date() + 2 * day }
        a.tick()
        try await until("the daily check saw it") { a.access == .expired }
        XCTAssertEqual(homeShown, 0)
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
        XCTAssertEqual(titles(a), ["Signed in as a@example.com · Trial, 12 days left"], "no Buy in the menu with 12 days left")
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
        XCTAssertEqual(titles(a), ["Not signed in", "Sign in to start your free trial…"])
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
        XCTAssertEqual(titles(a), ["Not signed in", "Sign in to start your free trial…"])
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
        XCTAssertEqual(titles(a), ["Signed in as a@example.com · Yours forever"])
    }

    func testExpiredBlocksFnAndBuyOpensThePlanChoice() async throws {
        try tokens.write("tok-1")
        server.handler = { [unowned self] _ in license("expired", endsIn: -day) }
        let a = account()
        try await until("checked at launch") { a.access == .expired }
        XCTAssertFalse(a.allowFnDown())
        XCTAssertEqual(hints.last, "Trial ended. Pick a plan to keep shepetal.")
        XCTAssertTrue(titles(a).contains("Get shepetal: $23.99 once or $0.99 a month…"))
        let sent = server.requests.count
        a.buy()
        XCTAssertEqual(opened, [plans], "the site's plan choice: $23.99 once or $0.99 a month")
        XCTAssertEqual(server.requests.count, sent, "no checkout request: the buyer picks the plan on the site")
        XCTAssertFalse(plans.absoluteString.contains("tok-1"), "the token never goes into an address")
    }

    func testAPurchaseOnTheWebsiteUnlocksOnTheNextFnPress() async throws {
        try tokens.write("tok-1")
        var status = "expired"
        server.handler = { [unowned self] _ in license(status, endsIn: -day) }
        let a = account()
        try await until("checked at launch") { a.access == .expired }
        XCTAssertTrue(titles(a).contains("Get shepetal: $23.99 once or $0.99 a month…"))
        status = "active"  // paid on shepetal.app
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
        var reply = license("trial", endsIn: 5 * day)
        server.handler = { _ in reply }
        let a = account()
        try await until("checked at launch") { a.access == .trial(daysLeft: 5) }
        a.buy()
        XCTAssertEqual(opened, [plans])
        reply = license("active")  // the lifetime license, bought on the site
        a.now = { Date() + 120 }
        a.tick()  // a minute later, not 24 h
        try await until("re-checked after checkout") { a.access == .lifetime }
        XCTAssertEqual(titles(a), ["Signed in as a@example.com · Yours forever"])
    }

    func testBuyingTheMonthlyPlanShowsUpTooAndDictates() async throws {
        try tokens.write("tok-1")
        var reply = license("expired", endsIn: -day)
        server.handler = { _ in reply }
        let a = account()
        try await until("checked at launch") { a.access == .expired }
        a.buy()
        let through = Date() + 30 * day
        reply = monthly(through)  // $0.99 a month, bought on the site
        a.now = { Date() + 120 }
        a.tick()
        try await until("re-checked after checkout") { a.access.isPaid }
        let paid = try XCTUnwrap(a.state.license?.subscription?.paidThrough)
        XCTAssertEqual(a.access, .subscription(paidThrough: paid, renews: true))
        XCTAssertTrue(a.allowFnDown())
        XCTAssertEqual(titles(a), ["Signed in as a@example.com · $0.99 a month, renews \(AccountText.day(paid))"], "no Buy in the menu")
    }

    /// Manage subscription opens the Stripe Billing Portal from the app, with the token, then re-checks for an hour
    /// so a cancel there shows up here: "Yours until <date>", and dictation still works until then.
    func testManageOpensTheBillingPortalAndACancelShowsUp() async throws {
        try tokens.write("tok-1")
        let through = Date() + 10 * day
        var reply = monthly(through)
        server.handler = { r in r.path == "/api/billing/portal" ? (200, ["url": "https://billing.stripe.com/p/session/test_1"]) : reply }
        let a = account()
        try await until("checked at launch") { a.access.isPaid }
        XCTAssertTrue(a.access.canManage)
        a.manage()
        try await until("portal opened") { !opened.isEmpty }
        XCTAssertEqual(opened, [URL(string: "https://billing.stripe.com/p/session/test_1")!])
        XCTAssertEqual(server.requests.last?.path, "/api/billing/portal")
        XCTAssertEqual(server.requests.last?.headers["authorization"], "Bearer tok-1")
        reply = monthly(through, renews: false)  // cancelled in the portal
        a.now = { Date() + 120 }
        a.tick()
        try await until("re-checked after the portal") { a.access == .subscription(paidThrough: a.state.license!.subscription!.paidThrough!, renews: false) }
        XCTAssertTrue(a.allowFnDown(), "a cancelled subscription works until its period ends")
        XCTAssertTrue(a.summaryLine.hasSuffix("Yours until \(AccountText.day(a.state.license!.subscription!.paidThrough!))"), a.summaryLine)

        // Its period ends, with the Mac offline: it stops on time, and the menu offers the plans again.
        server.handler = { _ in (0, [:]) }
        a.now = { through + 60 }
        XCTAssertFalse(a.allowFnDown())
        XCTAssertEqual(a.access, .subscriptionEnded)
        XCTAssertEqual(hints.last, "Your subscription ended. Pick a plan to keep shepetal.")
        XCTAssertTrue(titles(a).contains("Get shepetal: $23.99 once or $0.99 a month…"))
    }

    /// "Works offline" for a subscriber: the paid period plus 14 days without reaching the service.
    func testASubscriptionKeepsDictatingOfflineThroughItsPeriodPlusFourteenDays() async throws {
        try tokens.write("tok-1")
        let through = Date() + 20 * day
        server.handler = { [unowned self] _ in monthly(through) }
        let a = account()
        try await until("checked at launch") { a.access.isPaid }

        server.handler = { _ in (0, [:]) }  // offline from now on
        for later in [8 * day, 20 * day + 60, 33 * day] {
            let b = account()
            b.now = { Date() + later }
            try await until("the launch check failed") { b.checkTask == nil && b.message.contains("Could not check") }
            XCTAssertTrue(b.allowFnDown(), "\(Int(later / day)) days offline still dictates")
        }
        let c = account()
        c.now = { [day] in Date() + 35 * day }  // paid period + 15 days
        try await until("the launch check failed") { c.checkTask == nil && c.message.contains("Could not check") }
        XCTAssertFalse(c.allowFnDown())
        XCTAssertEqual(c.access, .unchecked)
        XCTAssertEqual(hints.last, "Connect to the internet so Shepetal can check your license")
    }

    func testAFailedPaymentBlocksFnAndManageFixesIt() async throws {
        try tokens.write("tok-1")
        var reply = monthly(Date() - 60, status: "expired", failed: true)
        server.handler = { r in r.path == "/api/billing/portal" ? (200, ["url": "https://billing.stripe.com/p/session/test_2"]) : reply }
        let a = account()
        try await until("checked at launch") { a.access == .paymentFailed }
        XCTAssertFalse(a.allowFnDown())
        XCTAssertEqual(hints.last, "Payment failed. Update your card in Manage subscription.")
        XCTAssertEqual(titles(a), ["Signed in as a@example.com · Payment failed"], "fixed on Home, not bought again from the menu")
        XCTAssertEqual(homeShown, 1, "Home, with Manage subscription, opens once at launch")
        a.manage()
        try await until("portal opened") { !opened.isEmpty }
        reply = monthly(Date() + 30 * day)  // a new card, the invoice paid
        a.now = { Date() + 120 }
        a.tick()
        try await until("re-checked") { a.access.isPaid }
        XCTAssertTrue(a.allowFnDown())
    }

    func testManageWithARevokedTokenSignsOut() async throws {
        try tokens.write("tok-1")
        server.handler = { [unowned self] r in r.path == "/api/billing/portal" ? (401, ["error": "unauthorized"]) : monthly(Date() + 9 * day) }
        let a = account()
        try await until("checked at launch") { a.access.isPaid }
        a.manage()
        try await until("signed out") { a.access == .signedOut }
        XCTAssertNil(tokens.read())
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(titles(a).prefix(2), ["Not signed in", "Sign in to start your free trial…"])
    }

    func testUnauthorizedSignsOut() async throws {
        try tokens.write("tok-old")
        try AccountState(license: License(status: .active, trialEndsAt: nil, email: "a@example.com"),
                         lastGoodCheck: Date(), lastAttempt: Date()).sealed(with: "tok-old").save(stateURL(creating: true))
        server.handler = { _ in (401, ["error": "unauthorized"]) }
        let a = account()
        try await until("signed out by the 401") { a.access == .signedOut }
        XCTAssertNil(tokens.read(), "the token is dropped")
        XCTAssertFalse(a.allowFnDown())
        XCTAssertNil(AccountState.load(stateURL).license)
    }

    func testACachedTrialDictatesOfflineUntilItsEnd() async throws {
        try tokens.write("tok-1")
        server.handler = { _ in (0, [:]) }  // the service does not answer
        let ends = Date() + 10 * day
        try AccountState(license: License(status: .trial, trialEndsAt: ends, email: "a@example.com"),
                         lastGoodCheck: Date() - 6 * day, lastAttempt: Date() - 6 * day).sealed(with: "tok-1").save(stateURL(creating: true))
        let a = account()
        try await until("the launch check failed") { a.state.lastAttempt.map { Date().timeIntervalSince($0) < 60 } ?? false }
        XCTAssertEqual(a.access, .trial(daysLeft: 10))
        XCTAssertTrue(a.allowFnDown(), "6 days offline still dictates")
        XCTAssertTrue(a.message.contains("Could not check"))

        a.now = { Date() + 3 * 86_400 }  // 9 days since the last good check, 7 days before the trial ends
        XCTAssertTrue(a.allowFnDown(), "past 7 days offline a trial still dictates, until its end")
        XCTAssertEqual(a.access, .trial(daysLeft: 7))

        a.now = { Date() + 11 * 86_400 }  // a day past the trial's end, still offline
        XCTAssertFalse(a.allowFnDown(), "past its end dictation is off")
        XCTAssertEqual(a.access, .unchecked)
        XCTAssertEqual(hints.last, "Connect to the internet so Shepetal can check your license")
    }

    /// #254: a lifetime license keeps dictating however long the Mac stays offline. The check the service answered
    /// seals the cache; the next launches, with the service unreachable, still dictate a year later.
    func testALifetimeLicenseKeepsDictatingOffline() async throws {
        try tokens.write("tok-1")
        server.handler = { [unowned self] _ in license("active") }
        let a = account()
        try await until("checked at launch") { a.access == .lifetime }

        server.handler = { _ in (0, [:]) }  // offline from now on
        for later in [8 * day, 30 * day, 365 * day] {
            let b = account()
            b.now = { Date() + later }
            try await until("the launch check failed") { b.checkTask == nil && b.message.contains("Could not check") }
            XCTAssertTrue(b.allowFnDown(), "\(Int(later / day)) days offline still dictates")
            XCTAssertEqual(b.access, .lifetime)
            XCTAssertEqual(b.summaryLine, "Signed in as a@example.com · Yours forever")
        }
        XCTAssertTrue(hints.isEmpty, "nothing says to connect")
        XCTAssertEqual(homeShown, 0)
    }

    /// The other side of #254: account.json edited to a lifetime license, with no check the service answered, does not
    /// dictate. It is "not checked", and the next check that gets through says what the account really has.
    func testAnEditedCacheDoesNotDictate() async throws {
        try tokens.write("tok-1")
        server.handler = { _ in (0, [:]) }
        try AccountState(license: License(status: .active, trialEndsAt: nil, email: "a@example.com"),
                         lastGoodCheck: Date(), lastAttempt: Date()).save(stateURL(creating: true))
        let a = account()
        try await until("the launch check failed") { a.checkTask == nil && a.message.contains("Could not check") }
        XCTAssertEqual(a.access, .unchecked)
        XCTAssertFalse(a.allowFnDown())
        XCTAssertEqual(hints.last, "Connect to the internet so Shepetal can check your license")

        server.handler = { [unowned self] _ in license("expired", endsIn: -day) }
        a.now = { Date() + 120 }  // a blocked press re-checks at most once a minute
        XCTAssertFalse(a.allowFnDown())
        try await until("the service answered") { a.access == .expired }
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
                         lastGoodCheck: old, lastAttempt: old).sealed(with: "tok-1").save(stateURL)
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
