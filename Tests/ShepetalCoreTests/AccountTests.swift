import Foundation
import XCTest
@testable import ShepetalCore

/// The account contract (web/API.md) against a local stub server, and the trial / license / offline rules.
final class AccountTests: XCTestCase {
    private var server: StubServer!
    private var client: AccountClient!
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        server = try StubServer()
        XCTAssertNotEqual(server.port, 0)
        client = AccountClient(base: server.url)
    }

    private static let start: [String: Any] = ["device_code": "dev-1", "user_code": "ABCD-1234",
                                               "verification_uri_complete": "https://example.test/device?code=ABCD-1234",
                                               "expires_in": 600, "interval": 5]

    /// Replies to /api/device/token in order; the last one repeats.
    private func deviceFlow(_ replies: [(Int, [String: Any])]) {
        var left = replies
        server.handler = { r in
            if r.path == "/api/device/start" { return (200, Self.start) }
            let next = left.count > 1 ? left.removeFirst() : left[0]
            return next
        }
    }

    private func pending(_ e: String) -> (Int, [String: Any]) { (400, ["error": e]) }

    // MARK: device flow

    func testDeviceFlowPollsAtTheIntervalAndSlowsDownUntilGranted() async throws {
        deviceFlow([pending("authorization_pending"), pending("slow_down"), pending("authorization_pending"),
                    (200, ["access_token": "tok-1", "email": "a@example.com"])])
        let slept = Box<[TimeInterval]>([])
        let opened = Box<[URL]>([])
        let (token, email) = try await DeviceFlow.signIn(client, open: { opened.value.append($0.verificationURIComplete) },
                                                         sleep: { slept.value.append($0) })
        XCTAssertEqual(token, "tok-1")
        XCTAssertEqual(email, "a@example.com")
        XCTAssertEqual(opened.value, [URL(string: "https://example.test/device?code=ABCD-1234")!])
        XCTAssertEqual(slept.value, [5, 5, 10, 10], "waits the interval before each poll; slow_down adds 5 s")
        let polls = server.requests.filter { $0.path == "/api/device/token" }
        XCTAssertEqual(polls.count, 4)
        XCTAssertTrue(polls.allSatisfy { $0.method == "POST" && $0.body["device_code"] as? String == "dev-1" })
        XCTAssertEqual(server.requests.first?.method, "POST")
    }

    func testDeviceFlowExpiredAndDeniedFail() async throws {
        for (error, word) in [("expired_token", "expired"), ("access_denied", "cancelled")] {
            deviceFlow([pending("authorization_pending"), pending(error)])
            do {
                _ = try await DeviceFlow.signIn(client, open: { _ in }, sleep: { _ in })
                XCTFail("\(error) must end the sign-in")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(word), error.localizedDescription)
            }
        }
    }

    func testDeviceFlowGivesUpWhenTheCodeExpires() async throws {
        deviceFlow([pending("authorization_pending")])
        let clock = Box(Date(timeIntervalSince1970: 1_000_000))
        do {
            _ = try await DeviceFlow.signIn(client, open: { _ in }, sleep: { clock.value += $0 }, now: { clock.value })
            XCTFail("polling must stop after expires_in")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("expired"))
        }
        let polls = server.requests.filter { $0.path == "/api/device/token" }.count
        XCTAssertEqual(polls, 119, "600 s at 5 s, the poll at the deadline is not sent")
    }

    func testDeviceFlowKeepsPollingThroughADroppedConnection() async throws {
        var n = 0
        server.handler = { r in
            if r.path == "/api/device/start" { return (200, Self.start) }
            n += 1
            return n == 1 ? (0, [:]) : (200, ["access_token": "tok-2", "email": "b@example.com"])
        }
        let (token, _) = try await DeviceFlow.signIn(client, open: { _ in }, sleep: { _ in })
        XCTAssertEqual(token, "tok-2")
    }

    func testDeviceFlowKeepsPollingThroughAServerError() async throws {
        deviceFlow([(502, ["error": "bad gateway"]), (503, [:]), (200, ["access_token": "tok-3", "email": "c@example.com"])])
        let (token, _) = try await DeviceFlow.signIn(client, open: { _ in }, sleep: { _ in })
        XCTAssertEqual(token, "tok-3")
    }

    func testDeviceFlowOpensOnlyWebPages() async throws {
        var start = Self.start
        start["verification_uri_complete"] = "file:///System/Applications/Calculator.app"
        server.handler = { [start] _ in (200, start) }
        let opened = Box(0)
        do {
            _ = try await DeviceFlow.signIn(client, open: { _ in opened.value += 1 }, sleep: { _ in })
            XCTFail("a file URL must not be opened")
        } catch {}
        XCTAssertEqual(opened.value, 0)
        XCTAssertTrue(DeviceFlow.isWebPage(URL(string: "https://shepetal.backant.io/device?code=A")!))
        XCTAssertTrue(DeviceFlow.isWebPage(URL(string: "http://localhost:3000/device")!))
        XCTAssertFalse(DeviceFlow.isWebPage(URL(string: "http://evil.example/device")!))
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
        XCTAssertEqual(Access.signedOut.blockedHint, "Sign in to start your free 30-day trial")
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

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
