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
        let url = AppLogin.loginURL(base: URL(string: "https://shepetal.backant.io")!, pkce: p)
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.scheme, "https")
        XCTAssertEqual(c.host, "shepetal.backant.io")
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
        XCTAssertTrue(AccountClient.isWebPage(URL(string: "https://shepetal.backant.io/app/login")!))
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
    }

    func testBaseURLDefaultsToTheServiceAndHonorsTheOverride() {
        unsetenv("SHEPETAL_ACCOUNT_URL")
        XCTAssertEqual(AccountClient().base.absoluteString, "https://shepetal.backant.io")
        setenv("SHEPETAL_ACCOUNT_URL", "http://127.0.0.1:9", 1)
        defer { unsetenv("SHEPETAL_ACCOUNT_URL") }
        XCTAssertEqual(AccountClient().base.absoluteString, "http://127.0.0.1:9")
    }

    // MARK: rules

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func state(_ status: LicenseStatus, ends: Date? = nil, checkedAgo: TimeInterval) -> AccountState {
        AccountState(license: License(status: status, trialEndsAt: ends, email: "a@example.com"),
                     lastGoodCheck: now - checkedAgo, lastAttempt: now - checkedAgo)
    }

    func testAccessForEachStatus() {
        XCTAssertEqual(AccountPolicy.access(signedIn: false, state: state(.active, checkedAgo: 0), now: now), .signedOut)
        XCTAssertEqual(AccountPolicy.access(signedIn: true, state: AccountState(), now: now), .unchecked)
        XCTAssertEqual(AccountPolicy.access(signedIn: true, state: state(.active, checkedAgo: 0), now: now), .lifetime)
        XCTAssertEqual(AccountPolicy.access(signedIn: true, state: state(.expired, checkedAgo: 0), now: now), .expired)
        XCTAssertEqual(AccountPolicy.access(signedIn: true, state: state(.trial, ends: now + 12 * day - 60, checkedAgo: 0), now: now),
                       .trial(daysLeft: 12))
        XCTAssertEqual(AccountPolicy.access(signedIn: true, state: state(.trial, ends: now + 3600, checkedAgo: 0), now: now),
                       .trial(daysLeft: 1))
        // The cached end date counts offline too: the trial ends on time without a check.
        XCTAssertEqual(AccountPolicy.access(signedIn: true, state: state(.trial, ends: now - 1, checkedAgo: day), now: now), .expired)

        XCTAssertTrue(Access.trial(daysLeft: 3).allowsDictation)
        XCTAssertTrue(Access.lifetime.allowsDictation)
        for a in [Access.signedOut, .expired, .unchecked] { XCTAssertFalse(a.allowsDictation, "\(a)") }
    }

    func testWhatTheUserSees() {
        XCTAssertEqual(Access.trial(daysLeft: 12).summary, "Free trial: 12 days left")
        XCTAssertEqual(Access.trial(daysLeft: 1).summary, "Free trial: 1 day left")
        XCTAssertEqual(Access.lifetime.summary, "Yours forever")
        XCTAssertEqual(Access.signedOut.blockedHint, "Sign in with Google to start your free 30-day trial")
        XCTAssertEqual(Access.expired.blockedHint, "Trial ended: get Shepetal for $4.99")
        XCTAssertNil(Access.lifetime.blockedHint)
        XCTAssertNil(Access.trial(daysLeft: 2).blockedHint)
    }

    func testSevenDayOfflineGrace() {
        XCTAssertEqual(AccountPolicy.access(signedIn: true, state: state(.active, checkedAgo: 7 * day), now: now), .lifetime,
                       "exactly 7 days still counts")
        XCTAssertEqual(AccountPolicy.access(signedIn: true, state: state(.active, checkedAgo: 7 * day + 1), now: now), .unchecked)
        let active = state(.active, checkedAgo: 7 * day - 60)
        XCTAssertEqual(AccountPolicy.access(signedIn: true, state: active, now: now), .lifetime, "6.9 days offline still works")
        XCTAssertEqual(AccountPolicy.access(signedIn: true, state: state(.active, checkedAgo: 7 * day + 60), now: now), .unchecked)
        XCTAssertEqual(AccountPolicy.access(signedIn: true, state: state(.trial, ends: now + 20 * day, checkedAgo: 8 * day), now: now),
                       .unchecked)

        // A failed check keeps the cached license and the time of the last good one.
        let (failed, out) = AccountPolicy.apply(.failure(URLError(.notConnectedToInternet)), to: active, now: now)
        XCTAssertFalse(out)
        XCTAssertEqual(failed.license, active.license)
        XCTAssertEqual(failed.lastGoodCheck, active.lastGoodCheck)
        XCTAssertEqual(failed.lastAttempt, now)

        // A good one moves it.
        let fresh = License(status: .active, trialEndsAt: nil, email: "a@example.com")
        let (good, _) = AccountPolicy.apply(.success(.license(fresh)), to: active, now: now)
        XCTAssertEqual(good.lastGoodCheck, now)
    }

    func testUnauthorizedSignsOutAndClearsTheCache() {
        let (s, signedOut) = AccountPolicy.apply(.success(.unauthorized), to: state(.active, checkedAgo: 0), now: now)
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
