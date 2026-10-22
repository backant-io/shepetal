import Foundation
import XCTest
@testable import ShepetalCore

/// The account contract (web/API.md) against a local stub server: Google sign-in with PKCE, the license, checkout,
/// and the trial / license / offline rules.
final class AccountTests: XCTestCase {
    private var server: StubServer!
    private var client: AccountClient!
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        server = try StubServer()
        XCTAssertNotEqual(server.port, 0)
        client = AccountClient(base: server.url)
    }

    // MARK: Google sign-in with PKCE

    func testPKCEVerifierLengthAndCharset() {
        let allowed = Set(PKCE.unreserved)
        var seen = Set<String>()
        for _ in 0..<50 {
            let p = PKCE.generate()
            XCTAssertTrue((43...128).contains(p.verifier.count), "\(p.verifier.count)")
            XCTAssertTrue(p.verifier.allSatisfy(allowed.contains), p.verifier)
            XCTAssertGreaterThanOrEqual(p.state.count, 16)
            XCTAssertTrue(p.state.allSatisfy(allowed.contains), p.state)
            XCTAssertEqual(p.challenge, PKCE.challenge(for: p.verifier))
            seen.insert(p.verifier)
        }
        XCTAssertEqual(seen.count, 50, "a fresh verifier every time")
        XCTAssertEqual(Set(PKCE.unreserved).count, 66, "A-Z a-z 0-9 - . _ ~")
    }

    func testS256ChallengeMatchesTheRFC7636Vector() {
        // RFC 7636 Appendix B.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testLoginURL() throws {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "st4te")
        let url = AppLogin.loginURL(base: URL(string: "https://shepetal.app")!, pkce: p)
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.scheme, "https")
        XCTAssertEqual(c.host, "shepetal.app")
        XCTAssertEqual(c.path, "/app/login")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q, ["redirect_uri": "shepetal://auth", "state": "st4te",
                           "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "code_challenge_method": "S256"])
        XCTAssertFalse(q.keys.contains("code_verifier"), "the verifier never goes to the browser")
    }

    func testCallbackParsingAndStateCheck() throws {
        XCTAssertEqual(try AppLogin.code(from: URL(string: "shepetal://auth?code=abc123&state=st4te")!, state: "st4te"), "abc123")
        XCTAssertEqual(try AppLogin.code(from: URL(string: "shepetal://auth?state=st4te&code=a%2Bb")!, state: "st4te"), "a+b")
        for (bad, why) in [("shepetal://auth?code=abc123&state=other", "did not match"),
                           ("shepetal://auth?code=abc123", "did not match"),
                           ("shepetal://auth?state=st4te", "without a code"),
                           ("shepetal://auth?error=access_denied&state=st4te", "refused"),
                           ("shepetal://elsewhere?code=abc123&state=st4te", "wrong address"),
                           ("https://auth?code=abc123&state=st4te", "wrong address")] {
            XCTAssertThrowsError(try AppLogin.code(from: URL(string: bad)!, state: "st4te"), bad) { e in
                XCTAssertTrue(e.localizedDescription.contains(why), "\(bad): \(e.localizedDescription)")
            }
        }
    }

    func testTokenExchange() async throws {
        server.handler = { r in
            r.body["code"] as? String == "abc123" ? (200, ["access_token": "tok-1", "email": "a@example.com"])
                                                  : (400, ["error": "invalid_grant"])
        }
        let (token, email) = try await client.exchange(code: "abc123", verifier: "v-123")
        XCTAssertEqual(token, "tok-1")
        XCTAssertEqual(email, "a@example.com")
        let r = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/api/app/token")
        XCTAssertEqual(r.headers["content-type"], "application/json")
        XCTAssertEqual(r.body as? [String: String], ["code": "abc123", "code_verifier": "v-123", "redirect_uri": "shepetal://auth"])
        do {
            _ = try await client.exchange(code: "stale", verifier: "v-123")
            XCTFail("a refused code must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid_grant"), error.localizedDescription)
        }
        server.handler = { _ in (200, ["email": "a@example.com"]) }
        do { _ = try await client.exchange(code: "abc123", verifier: "v"); XCTFail("no token, no sign-in") } catch {}
    }

    func testOnlyWebPagesAreOpened() {
        XCTAssertTrue(AccountClient.isWebPage(URL(string: "https://shepetal.app/app/login")!))
        XCTAssertTrue(AccountClient.isWebPage(URL(string: "http://localhost:3000/app/login")!))
        XCTAssertFalse(AccountClient.isWebPage(URL(string: "http://evil.example/app/login")!))
        XCTAssertFalse(AccountClient.isWebPage(URL(string: "file:///System/Applications/Calculator.app")!))
    }

    // MARK: license and checkout

    func testLicenseRepliesAndBearerToken() async throws {
        var reply: (Int, Any) = (200, [:])
        server.handler = { _ in reply }

        reply = (200, ["status": "trial", "trial_ends_at": "2026-11-19T21:00:00.000Z", "email": "a@example.com"])
        guard case let .license(trial) = try await client.license(token: "tok-1") else { return XCTFail() }
        XCTAssertEqual(trial.status, .trial)
        XCTAssertEqual(trial.trialEndsAt, ISO8601DateFormatter().date(from: "2026-11-19T21:00:00Z"))
        XCTAssertEqual(trial.email, "a@example.com")
        XCTAssertEqual(server.requests.last?.headers["authorization"], "Bearer tok-1")
        XCTAssertEqual(server.requests.last?.method, "GET")
        XCTAssertEqual(server.requests.last?.path, "/api/license")

        reply = (200, ["status": "active", "trial_ends_at": NSNull(), "email": "a@example.com"])
        guard case let .license(active) = try await client.license(token: "tok-1") else { return XCTFail() }
        XCTAssertEqual(active.status, .active)

        reply = (200, ["status": "expired", "trial_ends_at": "2026-10-01T00:00:00Z", "email": "a@example.com"])
        guard case let .license(expired) = try await client.license(token: "tok-1") else { return XCTFail() }
        XCTAssertEqual(expired.status, .expired)

        // The plans (web/API.md): lifetime, subscription, trial. A service from before them sends no plan.
        XCTAssertNil(active.subscription, "no plan field: active is the lifetime license")
        reply = (200, ["status": "active", "plan": "lifetime", "trial_ends_at": NSNull(), "paid_through": NSNull(),
                       "renews": false, "payment_failed": false, "email": "a@example.com"])
        guard case let .license(lifetime) = try await client.license(token: "tok-1") else { return XCTFail() }
        XCTAssertEqual(lifetime.plan, .lifetime)
        reply = (200, ["status": "active", "plan": "subscription", "trial_ends_at": NSNull(), "paid_through": "2026-11-21T21:30:21.000Z",
                       "renews": true, "payment_failed": false, "email": "a@example.com"])
        guard case let .license(monthly) = try await client.license(token: "tok-1") else { return XCTFail() }
        let through = ISO8601DateFormatter().date(from: "2026-11-21T21:30:21Z")!
        XCTAssertEqual(monthly.subscription, Subscription(paidThrough: through, renews: true, paymentFailed: false))
        XCTAssertEqual(monthly.plan, .subscription(paidThrough: through, renews: true))
        reply = (200, ["status": "expired", "plan": "subscription", "trial_ends_at": "2026-08-31T00:00:00.000Z",
                       "paid_through": "2026-10-21T21:30:40.000Z", "renews": true, "payment_failed": true, "email": "a@example.com"])
        guard case let .license(failed) = try await client.license(token: "tok-1") else { return XCTFail() }
        XCTAssertEqual(failed.subscription?.paymentFailed, true)
        XCTAssertNil(failed.plan, "a lapsed subscription pays for nothing")
        reply = (200, ["status": "active", "plan": "subscription", "trial_ends_at": NSNull(), "renews": true, "email": "a@example.com"])
        do { _ = try await client.license(token: "tok-1"); XCTFail("an active subscription needs its paid-through date") } catch {}

        reply = (401, ["error": "unauthorized"])
        let signedOut = try await client.license(token: "tok-1")
        XCTAssertEqual(signedOut, .unauthorized)

        reply = (500, ["error": "boom"])
        do { _ = try await client.license(token: "tok-1"); XCTFail("500 is a failed check, not a status") } catch {}

        reply = (200, ["status": "trial", "email": "a@example.com"])
        do { _ = try await client.license(token: "tok-1"); XCTFail("a trial needs an end date") } catch {}
    }

    func testCheckoutReturnsTheStripeURL() async throws {
        server.handler = { _ in (200, ["url": "https://checkout.stripe.com/c/pay/cs_test_1"]) }
        let url = try await client.checkout(token: "tok-1")
        XCTAssertEqual(url.absoluteString, "https://checkout.stripe.com/c/pay/cs_test_1")
        XCTAssertEqual(server.requests.last?.method, "POST")
        XCTAssertEqual(server.requests.last?.path, "/api/checkout")
        XCTAssertEqual(server.requests.last?.headers["authorization"], "Bearer tok-1")

        server.handler = { _ in (401, ["error": "unauthorized"]) }
        do { _ = try await client.checkout(token: "tok-1"); XCTFail("401 must throw") } catch let e as AccountError {
            XCTAssertEqual(e, .signedOut)
        }

        // Bought already: a dedicated error, so the app re-checks instead of saying "answered 409".
        server.handler = { _ in (409, ["error": "already_active"]) }
        do { _ = try await client.checkout(token: "tok-1"); XCTFail("409 must throw") } catch let e as AccountError {
            XCTAssertEqual(e, .alreadyBought)
        }
    }

    func testBuyOpensThePlanChoiceAndManageOpensTheBillingPortal() async throws {
        XCTAssertEqual(client.plansPage.absoluteString, server.url.absoluteString + "/account#plans")
        XCTAssertEqual(AccountClient(base: AccountClient.defaultBase).plansPage.absoluteString, "https://shepetal.app/account#plans")

        server.handler = { _ in (200, ["url": "https://billing.stripe.com/p/session/test_1"]) }
        let url = try await client.billingPortal(token: "tok-1")
        XCTAssertEqual(url.absoluteString, "https://billing.stripe.com/p/session/test_1")
        XCTAssertEqual(server.requests.last?.method, "POST")
        XCTAssertEqual(server.requests.last?.path, "/api/billing/portal")
        XCTAssertEqual(server.requests.last?.headers["authorization"], "Bearer tok-1")
        server.handler = { _ in (401, ["error": "unauthorized"]) }
        do { _ = try await client.billingPortal(token: "tok-1"); XCTFail("401 must throw") } catch let e as AccountError {
            XCTAssertEqual(e, .signedOut)
        }
        server.handler = { _ in (200, ["url": "javascript:alert(1)"]) }
        do { _ = try await client.billingPortal(token: "tok-1"); XCTFail("only web pages are opened") } catch {}
    }

    /// The site address is one constant (`Site.base`): no source line names another shepetal host.
    func testTheSiteAddressIsOneConstant() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources").standardized
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for f in files {
            for (n, line) in try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where line.contains("shepetal.backant.io") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                XCTFail("\(f.lastPathComponent):\(n + 1) names the old host; use Site.base")
            }
            let text = try String(contentsOf: f, encoding: .utf8)
            XCTAssertFalse(text.contains("\"https://shepetal.app") && f.lastPathComponent != "Account.swift", "\(f.lastPathComponent) writes the address itself")
        }
    }

    /// Updates come from the same site as the account: every shipped build keeps its SUFeedURL for good (make-app.sh).
    func testTheUpdateFeedIsOnTheSiteAndNoSourceLinksToGitHub() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
        let makeApp = try String(contentsOf: root.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8)
        XCTAssertTrue(makeApp.contains("SHEPETAL_DOMAIN=${SHEPETAL_DOMAIN:-\(Site.host)}\n"), "the feed's default domain is Site.host")
        // #277: the repository goes private, so the app links to no GitHub page.
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for f in files {
            for (n, line) in try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where line.contains("github.com") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                XCTFail("\(f.lastPathComponent):\(n + 1) links to GitHub")
            }
        }
    }

    func testBaseURLDefaultsToTheServiceAndHonorsTheOverride() {
        unsetenv("SHEPETAL_ACCOUNT_URL")
        XCTAssertEqual(AccountClient().base.absoluteString, "https://shepetal.app")
        XCTAssertEqual(AccountClient.defaultBase, Site.base, "one constant")
        XCTAssertEqual(Site.host, "shepetal.app")
        setenv("SHEPETAL_ACCOUNT_URL", "http://127.0.0.1:9", 1)
        defer { unsetenv("SHEPETAL_ACCOUNT_URL") }
        XCTAssertEqual(AccountClient().base.absoluteString, "http://127.0.0.1:9")
    }

    // MARK: rules

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private let token = "tok-1"

    /// A cache as a check the service answered leaves it: sealed with the token.
    private func state(_ status: LicenseStatus, ends: Date? = nil, checkedAgo: TimeInterval) -> AccountState {
        AccountState(license: License(status: status, trialEndsAt: ends, email: "a@example.com"),
                     lastGoodCheck: now - checkedAgo, lastAttempt: now - checkedAgo).sealed(with: token)
    }

    func testAccessForEachStatus() {
        XCTAssertEqual(AccountPolicy.access(token: nil, state: state(.active, checkedAgo: 0), now: now), .signedOut)
        XCTAssertEqual(AccountPolicy.access(token: token, state: AccountState(), now: now), .unchecked)
        XCTAssertEqual(AccountPolicy.access(token: token, state: state(.active, checkedAgo: 0), now: now), .lifetime)
        XCTAssertEqual(AccountPolicy.access(token: token, state: state(.expired, checkedAgo: 0), now: now), .expired)
        XCTAssertEqual(AccountPolicy.access(token: token, state: state(.trial, ends: now + 12 * day - 60, checkedAgo: 0), now: now),
                       .trial(daysLeft: 12))
        XCTAssertEqual(AccountPolicy.access(token: token, state: state(.trial, ends: now + 3600, checkedAgo: 0), now: now),
                       .trial(daysLeft: 1))
        // The cached end date counts offline too: the trial ends on time without a check.
        XCTAssertEqual(AccountPolicy.access(token: token, state: state(.trial, ends: now - 1, checkedAgo: day), now: now), .expired)

        XCTAssertTrue(Access.trial(daysLeft: 3).allowsDictation)
        XCTAssertTrue(Access.lifetime.allowsDictation)
        for a in [Access.signedOut, .expired, .unchecked] { XCTAssertFalse(a.allowsDictation, "\(a)") }
    }

    func testWhatTheUserSees() {
        XCTAssertEqual(Access.trial(daysLeft: 12).summary, "Trial, 12 days left")
        XCTAssertEqual(Access.trial(daysLeft: 1).summary, "Trial, 1 day left")
        XCTAssertEqual(Access.lifetime.summary, "Yours forever")
        XCTAssertEqual(Access.signedOut.blockedHint, "Sign in with Google to start your free 30-day trial")
        XCTAssertEqual(Access.expired.blockedHint, "Trial ended. Pick a plan to keep shepetal.")
        XCTAssertEqual(Access.subscriptionEnded.blockedHint, "Your subscription ended. Pick a plan to keep shepetal.")
        XCTAssertEqual(Access.paymentFailed.blockedHint, "Payment failed. Update your card in Manage subscription.")
        let nov21 = Date() + 30 * 86_400  // a renewal date ahead
        XCTAssertEqual(Access.subscription(paidThrough: nov21, renews: true).summary, "$0.99 a month, renews \(AccountText.day(nov21))")
        XCTAssertEqual(Access.subscription(paidThrough: nov21, renews: false).summary, "Yours until \(AccountText.day(nov21))")
        XCTAssertNil(Access.subscription(paidThrough: nov21, renews: true).blockedHint)
        XCTAssertEqual(Access.subscription(paidThrough: Date() - 86_400, renews: true).summary, "$0.99 a month",
                       "offline past the date, the renewal is not confirmed yet: no date that has gone by")
        XCTAssertEqual(AccountText.buy, "$23.99 once or $0.99 a month")
        for text in [AccountText.buy, AccountText.buyMenu, AccountText.trialEnded, AccountText.subscriptionEnded, AccountText.paymentFailed] {
            XCTAssertFalse(text.contains("4.99") && !text.contains("23.99"), "the retired price: \(text)")
            XCTAssertFalse(text.contains("!"), "bold, never loud: \(text)")
        }
        XCTAssertNil(Access.lifetime.blockedHint)
        XCTAssertNil(Access.trial(daysLeft: 2).blockedHint)
    }

    /// #254: "Yours forever" and "Works offline". A lifetime license the service confirmed keeps dictating however
    /// long the Mac stays offline; before, it stopped after 7 days. "active" is the one-time purchase (web/API.md).
    func testALifetimeLicenseWorksOfflineForGood() {
        XCTAssertEqual(License(status: .active, trialEndsAt: nil, email: "").plan, .lifetime)
        for status in [LicenseStatus.trial, .expired] { XCTAssertNil(License(status: status, trialEndsAt: nil, email: "").plan) }
        for ago in [0, 7 * day + 1, 8 * day, 365 * day, 10 * 365 * day] {
            XCTAssertEqual(AccountPolicy.access(token: token, state: state(.active, checkedAgo: ago), now: now), .lifetime,
                           "\(ago / day) days offline")
        }
        // Failed checks offline keep it, and keep its seal.
        var s = state(.active, checkedAgo: 30 * day)
        for _ in 0..<3 { s = AccountPolicy.apply(.failure(URLError(.notConnectedToInternet)), to: s, now: now, token: token).0 }
        XCTAssertEqual(AccountPolicy.access(token: token, state: s, now: now), .lifetime)
        // Online, the check still runs every 24 h, so a refunded license ends at the next answer.
        XCTAssertTrue(AccountPolicy.checkDue(state: state(.active, checkedAgo: 30 * day), now: now))
        let refunded = AccountPolicy.apply(.success(.license(License(status: .expired, trialEndsAt: nil, email: "a@example.com"))),
                                           to: s, now: now, token: token).0
        XCTAssertEqual(AccountPolicy.access(token: token, state: refunded, now: now), .expired)
    }

    /// The 7-day offline grace is for trials only (and a cached "expired", which dictates either way).
    func testTrialsKeepTheSevenDayOfflineGrace() {
        let ends = now + 20 * day
        XCTAssertEqual(AccountPolicy.access(token: token, state: state(.trial, ends: ends, checkedAgo: 7 * day), now: now),
                       .trial(daysLeft: 20), "exactly 7 days still counts")
        let trial = state(.trial, ends: ends, checkedAgo: 7 * day - 60)
        XCTAssertEqual(AccountPolicy.access(token: token, state: trial, now: now), .trial(daysLeft: 20), "6.9 days offline still works")
        XCTAssertEqual(AccountPolicy.access(token: token, state: state(.trial, ends: ends, checkedAgo: 7 * day + 1), now: now), .unchecked)
        XCTAssertEqual(AccountPolicy.access(token: token, state: state(.trial, ends: ends, checkedAgo: 8 * day), now: now), .unchecked)
        XCTAssertEqual(AccountPolicy.access(token: token, state: state(.expired, checkedAgo: 8 * day), now: now), .unchecked)

        // A failed check keeps the cached license and the time of the last good one.
        let (failed, out) = AccountPolicy.apply(.failure(URLError(.notConnectedToInternet)), to: trial, now: now, token: token)
        XCTAssertFalse(out)
        XCTAssertEqual(failed.license, trial.license)
        XCTAssertEqual(failed.lastGoodCheck, trial.lastGoodCheck)
        XCTAssertEqual(failed.lastAttempt, now)

        // A good one moves it.
        let fresh = License(status: .trial, trialEndsAt: ends, email: "a@example.com")
        let (good, _) = AccountPolicy.apply(.success(.license(fresh)), to: trial, now: now, token: token)
        XCTAssertEqual(good.lastGoodCheck, now)
    }

    /// No offline limit for a lifetime license makes account.json worth editing. Only a cache sealed from a service
    /// answer with this account's token counts; anything else is "not checked" until the next check.
    func testAnEditedCacheGrantsNoLicense() throws {
        let trial = state(.trial, ends: now + 5 * day, checkedAgo: day)
        XCTAssertEqual(AccountPolicy.access(token: token, state: trial, now: now), .trial(daysLeft: 5))

        var edited = trial
        edited.license?.status = .active
        XCTAssertEqual(AccountPolicy.access(token: token, state: edited, now: now), .unchecked, "status edited to active")
        edited = trial
        edited.license?.trialEndsAt = now + 300 * day
        XCTAssertEqual(AccountPolicy.access(token: token, state: edited, now: now), .unchecked, "trial end pushed out")
        edited = trial
        edited.lastGoodCheck = now + 3650 * day
        XCTAssertEqual(AccountPolicy.access(token: token, state: edited, now: now), .unchecked, "check time pushed out")
        edited = state(.active, checkedAgo: 0)
        edited.seal = nil
        XCTAssertEqual(AccountPolicy.access(token: token, state: edited, now: now), .unchecked, "no seal")
        edited.seal = "not base64!"
        XCTAssertEqual(AccountPolicy.access(token: token, state: edited, now: now), .unchecked, "garbage seal")
        XCTAssertEqual(AccountPolicy.access(token: "tok-2", state: state(.active, checkedAgo: 0), now: now), .unchecked,
                       "another account's cache, or any token typed into the Keychain")

        // The seal comes from the service's answer, for the token the check was sent with.
        let paid = License(status: .active, trialEndsAt: nil, email: "a@example.com")
        let (answered, _) = AccountPolicy.apply(.success(.license(paid)), to: AccountState(), now: now + 0.75, token: token)
        XCTAssertEqual(AccountPolicy.access(token: token, state: answered, now: now), .lifetime)
        XCTAssertEqual(AccountPolicy.access(token: "tok-2", state: answered, now: now), .unchecked)

        // The seal survives the file, whose dates have whole seconds; an edit to the file does not.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("account.json")
        try answered.save(url)
        XCTAssertEqual(AccountPolicy.access(token: token, state: AccountState.load(url), now: now + 400 * day), .lifetime)
        try trial.save(url)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"trial\""), json)
        try json.replacingOccurrences(of: "\"trial\"", with: "\"active\"").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AccountPolicy.access(token: token, state: AccountState.load(url), now: now), .unchecked,
                       "account.json edited to active")
    }

    /// Seals already in account.json must keep verifying in every later build and on every macOS: a change here
    /// leaves each lifetime user who is offline at the update unable to dictate. The expected values were computed
    /// outside Swift (Python hmac over the documented bytes). Change the format only with a migration.
    // MARK: the subscription

    private func monthly(through: Date, renews: Bool = true, failed: Bool = false, status: LicenseStatus = .active,
                         checkedAgo: TimeInterval = 0) -> AccountState {
        AccountState(license: License(status: status, trialEndsAt: status == .active ? nil : now - 40 * day, email: "a@example.com",
                                      subscription: Subscription(paidThrough: through, renews: renews, paymentFailed: failed)),
                     lastGoodCheck: now - checkedAgo, lastAttempt: now - checkedAgo).sealed(with: token)
    }

    /// $0.99 a month: it works while paid. Offline, a renewing one keeps working 14 days past its paid-through
    /// date, so "Works offline" holds across a renewal the app has not heard about; the next check moves the date.
    func testASubscriptionWorksThroughItsPaidPeriodPlusFourteenDaysOffline() {
        let through = now + 10 * day
        let sub = Access.subscription(paidThrough: through, renews: true)
        XCTAssertEqual(AccountPolicy.access(token: token, state: monthly(through: through), now: now), sub)
        XCTAssertTrue(sub.allowsDictation)
        XCTAssertTrue(sub.isPaid)
        XCTAssertTrue(sub.canManage)
        // 20 days offline, inside the paid period: the trial's 7-day limit does not apply.
        XCTAssertEqual(AccountPolicy.access(token: token, state: monthly(through: through, checkedAgo: 20 * day), now: now), sub)
        XCTAssertEqual(AccountPolicy.access(token: token, state: monthly(through: through), now: through + 13 * day), sub,
                       "13 days past the paid period, offline, still works")
        XCTAssertEqual(AccountPolicy.access(token: token, state: monthly(through: through), now: through + 14 * day), .unchecked,
                       "14 days past it needs a check")
        // Online, the daily check renews it: the cache moves to the next period.
        let renewed = AccountPolicy.apply(.success(.license(License(status: .active, trialEndsAt: nil, email: "a@example.com",
                                                                    subscription: Subscription(paidThrough: through + 30 * day, renews: true)))),
                                          to: monthly(through: through), now: through + day, token: token).0
        XCTAssertEqual(AccountPolicy.access(token: token, state: renewed, now: through + 20 * day),
                       .subscription(paidThrough: through + 30 * day, renews: true))
        XCTAssertTrue(AccountPolicy.checkDue(state: monthly(through: through, checkedAgo: day), now: now), "checked every 24 h")
    }

    /// Cancelled, it works until its period ends, and not a day longer offline.
    func testACancelledSubscriptionWorksUntilItsPeriodEnds() {
        let through = now + 3 * day
        let cancelled = monthly(through: through, renews: false)
        XCTAssertEqual(AccountPolicy.access(token: token, state: cancelled, now: now), .subscription(paidThrough: through, renews: false))
        XCTAssertEqual(AccountPolicy.access(token: token, state: cancelled, now: through - 1), .subscription(paidThrough: through, renews: false))
        XCTAssertEqual(AccountPolicy.access(token: token, state: cancelled, now: through), .subscriptionEnded)
        XCTAssertFalse(Access.subscriptionEnded.allowsDictation)
        // The service's answer after the end says the same.
        let ended = monthly(through: through, renews: false, status: .expired, checkedAgo: 0)
        XCTAssertEqual(AccountPolicy.access(token: token, state: ended, now: now), .subscriptionEnded)
    }

    func testAFailedRenewalStopsDictationUntilTheCardWorks() {
        let failed = monthly(through: now - 60, failed: true, status: .expired)
        XCTAssertEqual(AccountPolicy.access(token: token, state: failed, now: now), .paymentFailed)
        XCTAssertFalse(Access.paymentFailed.allowsDictation)
        XCTAssertTrue(Access.paymentFailed.canManage, "Manage subscription is where the card is changed")
        // A lapsed subscription inside the first 30 days leaves the trial running, as the service says.
        let inTrial = AccountState(license: License(status: .trial, trialEndsAt: now + 9 * day, email: "a@example.com",
                                                    subscription: Subscription(paidThrough: now - day, renews: true, paymentFailed: true)),
                                   lastGoodCheck: now, lastAttempt: now).sealed(with: token)
        XCTAssertEqual(AccountPolicy.access(token: token, state: inTrial, now: now), .trial(daysLeft: 9))
    }

    /// The subscription's dates are sealed too: pushing paid_through out, turning renews on or clearing a failed
    /// payment in account.json grants nothing.
    func testAnEditedSubscriptionGrantsNothing() throws {
        let through = now + 2 * day
        let sealed = monthly(through: through, renews: false)
        let edits: [(inout AccountState) -> Void] = [
                     { [day] in $0.license?.subscription?.paidThrough = through + 365 * day },
                     { $0.license?.subscription?.renews = true },
                     { $0.license?.subscription = nil },  // a subscription edited into the lifetime license
                     { $0.license?.subscription?.paymentFailed = true }]
        for edit in edits {
            var s = sealed
            edit(&s)
            XCTAssertEqual(AccountPolicy.access(token: token, state: s, now: now), .unchecked)
        }
        var failed = monthly(through: now - 60, failed: true, status: .expired)
        failed.license?.subscription?.paymentFailed = false
        failed.license?.status = .active
        XCTAssertEqual(AccountPolicy.access(token: token, state: failed, now: now), .unchecked)

        // Through the file: a sealed subscription survives the round trip.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("account.json")
        let answered = AccountPolicy.apply(.success(.license(License(status: .active, trialEndsAt: nil, email: "a@example.com",
                                                                     subscription: Subscription(paidThrough: through.addingTimeInterval(0.4), renews: true)))),
                                           to: AccountState(), now: now + 0.6, token: token).0
        try answered.save(url)
        XCTAssertEqual(AccountPolicy.access(token: token, state: AccountState.load(url), now: now),
                       .subscription(paidThrough: AccountState.load(url).license!.subscription!.paidThrough!, renews: true))
    }

    func testTheSealFormatNeverChanges() {
        let paid = AccountState(license: License(status: .active, trialEndsAt: nil, email: "a@example.com"), lastGoodCheck: now)
        XCTAssertEqual(paid.sealed(with: token).seal, "XhSFAd/JP4hbmdANIb7wJOOgp6Bt+2GvA/Nh5a0AtaY=")
        let trial = AccountState(license: License(status: .trial, trialEndsAt: now + 5 * day, email: "a@example.com"),
                                 lastGoodCheck: now - day, lastAttempt: now)
        XCTAssertEqual(trial.sealed(with: token).seal, "ZjjVYOW2XSAw+w40UTo5IcFU1+VPDkIf51i1DO03rWg=",
                       "lastAttempt is not sealed: a failed check keeps the seal")
        // v2, a subscription: computed outside Swift too (Python hmac over the documented bytes).
        let sub = AccountState(license: License(status: .active, trialEndsAt: nil, email: "a@example.com",
                                                subscription: Subscription(paidThrough: now + 30 * day, renews: true, paymentFailed: false)),
                               lastGoodCheck: now)
        XCTAssertEqual(sub.sealed(with: token).seal, "okdVTdbwttmflV/zvnbZxW67+ufZtzW+Rep0+7TuWU4=")
    }

    func testUnauthorizedSignsOutAndClearsTheCache() {
        let (s, signedOut) = AccountPolicy.apply(.success(.unauthorized), to: state(.active, checkedAgo: 0), now: now, token: token)
        XCTAssertTrue(signedOut)
        XCTAssertNil(s.license)
        XCTAssertNil(s.lastGoodCheck)
    }

    func testCheckSchedule() {
        XCTAssertTrue(AccountPolicy.checkDue(state: AccountState(), now: now), "at launch")
        XCTAssertFalse(AccountPolicy.checkDue(state: state(.active, checkedAgo: 23 * 3600), now: now))
        XCTAssertTrue(AccountPolicy.checkDue(state: state(.active, checkedAgo: 24 * 3600 + 1), now: now), "every 24 h")
        var failed = state(.active, checkedAgo: 2 * day)
        failed.lastAttempt = now - 1800
        XCTAssertFalse(AccountPolicy.checkDue(state: failed, now: now), "a failed check waits an hour")
        failed.lastAttempt = now - 3601
        XCTAssertTrue(AccountPolicy.checkDue(state: failed, now: now))
    }

    func testStateFileIsOwnerOnlyAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepetal-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("account.json")
        let s = state(.trial, ends: now + 5 * day, checkedAgo: 60)
        try s.save(url)
        XCTAssertEqual(AccountState.load(url), s)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(AccountState.load(dir.appendingPathComponent("missing.json")), AccountState())
    }

    // MARK: model names

    func testEngineLabelsNeverNameAModel() {
        let tier = ModelTier(primary: .parakeetV3, fallback: .whisperLargeV3Turbo)
        XCTAssertEqual(EngineLabel.of(SpeechModel.parakeetV3.rawValue, tier: tier), "standard")
        XCTAssertEqual(EngineLabel.of(SpeechModel.whisperLargeV3Turbo.rawValue, tier: tier), "alternative")
        XCTAssertEqual(EngineLabel.status(SpeechModel.parakeetV3.rawValue, tier: tier),
                       "On-device speech recognition (standard engine)")
        let titles = EngineLabel.retryChoices(current: SpeechModel.parakeetV3.rawValue, tier: tier).map(\.title)
        XCTAssertEqual(titles, ["With the standard engine (current)", "With the alternative engine"])
        XCTAssertEqual(EngineLabel.retryChoices(current: SpeechModel.parakeetV3.rawValue, tier: tier).last?.model, .whisperLargeV3Turbo)
        let all = titles + [EngineLabel.status("ggml-base.en-q5_1", tier: tier)]
        for t in all { XCTAssertNil(t.range(of: "parakeet|whisper|ggml|v3|turbo", options: [.regularExpression, .caseInsensitive]), t) }
    }
}
