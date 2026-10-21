import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Google sign-in, free trial, the lifetime license and the monthly subscription against the account service
// (web/API.md on feat/web).
// These calls are the app's only network use: sign-in, the license check and checkout. Nothing here
// runs during dictation, and audio and text never go through it.

/// Google sign-in for a native app (RFC 8252) with PKCE (RFC 7636): the app opens
/// <base>/app/login?redirect_uri=shepetal://auth&state=…&code_challenge=…&code_challenge_method=S256 in an
/// ASWebAuthenticationSession, gets shepetal://auth?code=…&state=… back, and trades the code and the verifier
/// at POST /api/app/token for {access_token, email}.
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    /// RFC 7636 4.1: 43 to 128 characters from the unreserved set.
    public static let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
        self.state = state
    }

    /// A fresh 64-character verifier and a 32-character state from the system's secure random generator.
    public static func generate() -> PKCE {
        var rng = SystemRandomNumberGenerator()
        func random(_ n: Int) -> String { String((0..<n).map { _ in unreserved.randomElement(using: &rng)! }) }
        return PKCE(verifier: random(64), state: random(32))
    }

    /// S256: base64url(SHA-256(ASCII(verifier))) without padding.
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum AppLogin {
    public static let redirectURI = "shepetal://auth"
    public static let callbackScheme = "shepetal"

    public static func loginURL(base: URL, pkce: PKCE) -> URL {
        var c = URLComponents(url: base.appendingPathComponent("/app/login"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "redirect_uri", value: redirectURI),
                        URLQueryItem(name: "state", value: pkce.state),
                        URLQueryItem(name: "code_challenge", value: pkce.challenge),
                        URLQueryItem(name: "code_challenge_method", value: "S256")]
        return c.url!
    }

    /// The code from shepetal://auth?code=…&state=…, only when the state is the one this sign-in sent.
    public static func code(from callback: URL, state: String) throws -> String {
        let c = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        guard c?.scheme == callbackScheme, c?.host == "auth" else { throw AccountError("Sign-in came back to the wrong address") }
        let items = c?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { throw AccountError("Sign-in answer did not match this sign-in. Try again.") }
        if let error = value("error") { throw AccountError("Sign-in was refused (\(error))") }
        guard let code = value("code"), !code.isEmpty else { throw AccountError("Sign-in came back without a code") }
        return code
    }
}

public enum LicenseStatus: String, Codable, Sendable { case trial, active, expired }

/// The monthly subscription in a license answer (plan "subscription" in web/API.md).
public struct Subscription: Codable, Equatable, Sendable {
    /// The end of the last paid period. It works until then.
    public var paidThrough: Date?
    /// It charges again at paidThrough. False once cancelled: it ends at paidThrough.
    public var renews: Bool
    /// The last renewal could not be charged: the card needs updating (Manage subscription).
    public var paymentFailed: Bool

    public init(paidThrough: Date?, renews: Bool, paymentFailed: Bool = false) {
        self.paidThrough = paidThrough; self.renews = renews; self.paymentFailed = paymentFailed
    }
}

/// GET /api/license
public struct License: Codable, Equatable, Sendable {
    public var status: LicenseStatus
    public var trialEndsAt: Date?
    public var email: String
    /// Set when the service says plan "subscription"; nil for the lifetime license, the trial, and a service
    /// from before the plans (whose "active" is the lifetime license).
    public var subscription: Subscription?

    public init(status: LicenseStatus, trialEndsAt: Date?, email: String, subscription: Subscription? = nil) {
        self.status = status; self.trialEndsAt = trialEndsAt; self.email = email; self.subscription = subscription
    }

    /// What is paid for now, nil for a trial or an expired license (an ended subscription included).
    public var plan: Plan? {
        guard status == .active else { return nil }
        guard let sub = subscription else { return .lifetime }
        // An active subscription always has a paid-through date (the client refuses one without); without it, nothing is paid.
        return .subscription(paidThrough: sub.paidThrough ?? .distantPast, renews: sub.renews)
    }
}

/// A paid plan. `AccountPolicy.access` says how long each holds offline.
public enum Plan: Equatable, Sendable {
    /// Bought once ($23.99): works offline for good.
    case lifetime
    /// $0.99 a month, paid until `paidThrough`. Renewing, it holds offline 14 days past that; cancelled, it ends then.
    case subscription(paidThrough: Date, renews: Bool)
}

public enum LicenseReply: Equatable, Sendable {
    case license(License)
    case unauthorized  // 401: the token is gone or revoked, so the user is signed out
}

public struct AccountError: LocalizedError, Equatable {
    public let errorDescription: String?
    /// The HTTP status behind it, 0 when there is none.
    public var status = 0
    public init(_ message: String, status: Int = 0) { errorDescription = message; self.status = status }

    /// 401 from checkout: the token is gone, so the app signs out.
    public static let signedOut = AccountError("Signed out: sign in again to buy", status: 401)
    /// 409 already_active from checkout: the license is bought, so the app checks it instead of paying twice.
    public static let alreadyBought = AccountError("You already own Shepetal", status: 409)
}

public struct AccountClient: Sendable {
    public static let defaultBase = URL(string: "https://shepetal.backant.io")!
    public let base: URL
    private let session: URLSession

    /// SHEPETAL_ACCOUNT_URL overrides the service (tests point it at a local stub).
    public init(base: URL? = nil, session: URLSession? = nil) {
        self.base = base ?? ProcessInfo.processInfo.environment["SHEPETAL_ACCOUNT_URL"].flatMap(URL.init(string:))
            ?? Self.defaultBase
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config)
    }

    /// POST /api/app/token: the code from the callback and the PKCE verifier for the account token.
    public func exchange(code: String, verifier: String) async throws -> (token: String, email: String) {
        let (status, data) = try await send("POST", "/api/app/token",
                                            json: ["code": code, "code_verifier": verifier, "redirect_uri": AppLogin.redirectURI])
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200, let token = body["access_token"] as? String, !token.isEmpty else {
            if let e = body["error"] as? String { throw AccountError("Sign-in failed on shepetal.backant.io (\(e))", status: status) }
            throw Self.unexpected(status)
        }
        return (token, body["email"] as? String ?? "")
    }

    public func license(token: String) async throws -> LicenseReply {
        let (status, data) = try await send("GET", "/api/license", token: token)
        if status == 401 { return .unauthorized }
        guard status == 200,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let s = (body["status"] as? String).flatMap(LicenseStatus.init(rawValue:)) else { throw Self.unexpected(status) }
        let ends = (body["trial_ends_at"] as? String).flatMap(Self.parseDate)
        if s == .trial, ends == nil { throw AccountError("The account service sent a trial without an end date") }
        var sub: Subscription?
        if body["plan"] as? String == "subscription" {
            let through = (body["paid_through"] as? String).flatMap(Self.parseDate)
            if s == .active, through == nil { throw AccountError("The account service sent a subscription without a paid-through date") }
            sub = Subscription(paidThrough: through, renews: body["renews"] as? Bool ?? false,
                               paymentFailed: body["payment_failed"] as? Bool ?? false)
        }
        return .license(License(status: s, trialEndsAt: ends, email: body["email"] as? String ?? "", subscription: sub))
    }

    /// POST /api/billing/portal: the Stripe Billing Portal, where a subscriber cancels, resumes or changes the card.
    public func billingPortal(token: String) async throws -> URL {
        let (status, data) = try await send("POST", "/api/billing/portal", token: token, json: [:])
        if status == 401 { throw AccountError.signedOut }
        guard status == 200, let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let s = body["url"] as? String, let url = URL(string: s), AccountClient.isWebPage(url)
        else { throw Self.unexpected(status) }
        return url
    }

    /// The plan choice on the site ($23.99 once or $0.99 a month), where Buy goes. Signing in there uses the
    /// browser's own session, so the app sends no token in the address.
    public var plansPage: URL {
        var c = URLComponents(url: base.appendingPathComponent("/account"), resolvingAgainstBaseURL: false)!
        c.fragment = "plans"
        return c.url!
    }

    /// The Stripe Checkout page for the lifetime license (POST /api/checkout with no plan). The app opens
    /// `plansPage` instead, so the buyer picks the plan; this stays for the API contract.
    public func checkout(token: String) async throws -> URL {
        let (status, data) = try await send("POST", "/api/checkout", token: token, json: [:])
        if status == 401 { throw AccountError.signedOut }
        if status == 409 { throw AccountError.alreadyBought }
        guard status == 200, let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let s = body["url"] as? String, let url = URL(string: s), AccountClient.isWebPage(url)
        else { throw Self.unexpected(status) }
        return url
    }

    private func send(_ method: String, _ path: String, token: String? = nil,
                      json: [String: String]? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Only https pages are opened, plus http on this Mac for a local copy of the service.
    public static func isWebPage(_ url: URL) -> Bool {
        url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? ""))
    }

    static func unexpected(_ status: Int) -> AccountError {
        AccountError("The account service answered \(status)", status: status)
    }

    /// ISO 8601, with or without fractional seconds (JavaScript's toISOString has them).
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// What the user may do right now.
public enum Access: Equatable, Sendable {
    case signedOut
    case trial(daysLeft: Int)
    case lifetime
    /// The monthly plan, paid until `paidThrough`; `renews` false once cancelled.
    case subscription(paidThrough: Date, renews: Bool)
    case expired
    /// A subscription that ran out: cancelled, or its renewal was not paid and Stripe gave up.
    case subscriptionEnded
    /// The renewal could not be charged. Dictation is off until the card works.
    case paymentFailed
    /// Signed in, but no license the service confirmed: none yet, a trial not checked in the last 7 days, or a cache
    /// whose seal does not match.
    case unchecked

    public var allowsDictation: Bool {
        switch self {
        case .trial, .lifetime, .subscription: true
        case .signedOut, .expired, .subscriptionEnded, .paymentFailed, .unchecked: false
        }
    }

    /// A paid plan is in force (nothing to buy).
    public var isPaid: Bool {
        switch self {
        case .lifetime, .subscription: true
        default: false
        }
    }

    /// The Billing Portal has something for this user: a subscription to cancel, resume or fix.
    public var canManage: Bool {
        switch self {
        case .subscription, .paymentFailed: true
        default: false
        }
    }

    /// One line for Home.
    public var summary: String {
        switch self {
        case .signedOut: "Not signed in"
        case let .trial(days): "Trial, \(days) \(days == 1 ? "day" : "days") left"
        case .lifetime: "Yours forever"
        case let .subscription(through, renews):
            // Past the date while renewing: offline, the renewal is not confirmed yet, so no date that has gone by.
            !renews ? "Yours until \(AccountText.day(through))"
                : through > Date() ? "$0.99 a month, renews \(AccountText.day(through))" : "$0.99 a month"
        case .expired: "Trial ended"
        case .subscriptionEnded: "Subscription ended"
        case .paymentFailed: "Payment failed"
        case .unchecked: "License not checked"
        }
    }

    /// The text next to 🤫 when fn is pressed while dictation is off.
    public var blockedHint: String? {
        switch self {
        case .trial, .lifetime, .subscription: nil
        case .signedOut: AccountText.signIn
        case .expired: AccountText.trialEnded
        case .subscriptionEnded: AccountText.subscriptionEnded
        case .paymentFailed: AccountText.paymentFailed
        case .unchecked: "Connect to the internet so Shepetal can check your license"
        }
    }
}

public enum AccountText {
    public static let signIn = "Sign in with Google to start your free 30-day trial"
    public static let trialEnded = "Trial ended. Pick a plan to keep shepetal."
    public static let subscriptionEnded = "Your subscription ended. Pick a plan to keep shepetal."
    public static let paymentFailed = "Payment failed. Update your card in Manage subscription."
    /// Buy on Home: opens the plan choice on the site.
    public static let buy = "$23.99 once or $0.99 a month"
    /// The 🤫 menu item that opens the plan choice.
    public static let buyMenu = "Get shepetal: $23.99 once or $0.99 a month…"
    public static let manage = "Manage subscription"

    /// "Nov 21", in the user's language and time zone.
    public static func day(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// What is cached between launches (account.json in the data dir). The token itself is in the Keychain.
public struct AccountState: Codable, Equatable, Sendable {
    public var license: License?
    /// When the service last answered a license check.
    public var lastGoodCheck: Date?
    /// When a check was last tried, answered or not.
    public var lastAttempt: Date?
    /// HMAC-SHA256 of `license` and `lastGoodCheck`, keyed by the account token, set only from a service answer
    /// (`AccountPolicy.apply`). The token is in the Keychain, not in this file, so an edit here does not keep a seal.
    public var seal: String?

    public init(license: License? = nil, lastGoodCheck: Date? = nil, lastAttempt: Date? = nil) {
        self.license = license; self.lastGoodCheck = lastGoodCheck; self.lastAttempt = lastAttempt
    }

    /// This state with its seal for `token`.
    public func sealed(with token: String) -> AccountState {
        var s = self
        s.seal = Data(HMAC<SHA256>.authenticationCode(for: sealedBytes, using: SymmetricKey(data: Data(token.utf8))))
            .base64EncodedString()
        return s
    }

    /// Whether the seal is this license's and check time's under `token`.
    public func isSealed(with token: String) -> Bool {
        guard let seal, let code = Data(base64Encoded: seal) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: sealedBytes, using: SymmetricKey(data: Data(token.utf8)))
    }

    /// The sealed fields, one per line. Dates are in whole seconds, as the file has them, so a seal made in memory
    /// still matches after a round trip through the file. The bytes are built by hand rather than with JSONEncoder,
    /// so an OS update that changes the encoder's output cannot break every seal; `AccountTests` pins them. The
    /// email comes last because it is the only field that can contain a newline.
    /// v1 is a license without a subscription, as every build before the plans sealed it, so those caches keep
    /// verifying. v2 adds the subscription's paid-through date, renews and payment failed, so none can be edited.
    private var sealedBytes: Data {
        let iso = ISO8601DateFormatter()
        let common = [license?.status.rawValue ?? "", license?.trialEndsAt.map(iso.string) ?? "", lastGoodCheck.map(iso.string) ?? ""]
        var fields = ["shepetal-license-v1"] + common
        if let sub = license?.subscription {
            fields = ["shepetal-license-v2"] + common
                + ["subscription", sub.paidThrough.map(iso.string) ?? "", sub.renews ? "1" : "0", sub.paymentFailed ? "1" : "0"]
        }
        return Data((fields + [license?.email ?? ""]).joined(separator: "\n").utf8)
    }

    public static func load(_ url: URL) -> AccountState {
        guard let data = try? Data(contentsOf: url) else { return AccountState() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(AccountState.self, from: data)) ?? AccountState()
    }

    /// Owner-only (0600) from the moment it exists: written to a 0600 temp file, then renamed over.
    public func save(_ url: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let data = try e.encode(self)
        let tmp = url.path + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw AccountError("Cannot write \(tmp)") }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0,
              data.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == data.count,
              rename(tmp, url.path) == 0 else { unlink(tmp); throw AccountError("Cannot write \(url.path)") }
    }
}

public enum AccountPolicy {
    /// A trial stays valid this long without reaching the service. A lifetime license has no limit.
    public static let offlineGrace: TimeInterval = 7 * 86_400
    /// A renewing subscription holds this long past its paid-through date without a check, so "Works offline"
    /// stays true across a renewal the app has not heard about yet.
    public static let subscriptionOfflineGrace: TimeInterval = 14 * 86_400
    public static let checkEvery: TimeInterval = 86_400
    /// After a failed check, try again this much later.
    public static let retryAfterFailure: TimeInterval = 3_600

    /// `token` is the account token, nil when signed out. Only a cache sealed with it counts.
    public static func access(token: String?, state: AccountState, now: Date) -> Access {
        guard let token else { return .signedOut }
        guard let license = state.license, state.isSealed(with: token) else { return .unchecked }
        switch license.plan {
        case .lifetime?: return .lifetime  // "Yours forever" and "Works offline", however long it is offline (#254)
        case let .subscription(through, renews)?:
            // Paid up: it works, online or not. Renewing, the renewal the app has not seen yet gets 14 more days
            // offline; the daily check moves paidThrough as soon as the Mac is online. Cancelled, it ends on time.
            if now < through || (renews && now < through + subscriptionOfflineGrace) {
                return .subscription(paidThrough: through, renews: renews)
            }
            return renews ? .unchecked : .subscriptionEnded
        case nil: break  // a trial or an expired license: the offline grace below
        }
        guard let checked = state.lastGoodCheck, now.timeIntervalSince(checked) <= offlineGrace else { return .unchecked }
        // The cached end date counts even offline: a trial does not outlive its end by staying offline.
        if license.status == .trial, let end = license.trialEndsAt, end > now {
            return .trial(daysLeft: Int((end.timeIntervalSince(now) / 86_400).rounded(.up)))
        }
        if let sub = license.subscription { return sub.paymentFailed ? .paymentFailed : .subscriptionEnded }
        return .expired
    }

    /// A check is due at launch (no attempt yet), 24 h after the last good one, or an hour after a failed one.
    public static func checkDue(state: AccountState, now: Date) -> Bool {
        guard let attempt = state.lastAttempt else { return true }
        let good = state.lastGoodCheck ?? .distantPast
        if attempt > good.addingTimeInterval(1) { return now.timeIntervalSince(attempt) >= retryAfterFailure }
        return now.timeIntervalSince(good) >= checkEvery
    }

    /// Folds a check result into the cache. A 401 signs out (the caller drops the token); a failed
    /// check keeps the cached license, so a trial's 7-day grace counts from the last good check. An answer is
    /// sealed with `token`, the one the check was sent with.
    public static func apply(_ result: Result<LicenseReply, Error>, to state: AccountState, now: Date,
                             token: String) -> (AccountState, signedOut: Bool) {
        var s = state
        s.lastAttempt = now
        switch result {
        case let .success(.license(license)):
            s.license = license
            s.lastGoodCheck = now
            return (s.sealed(with: token), false)
        case .success(.unauthorized):
            return (AccountState(), true)
        case .failure:
            return (s, false)
        }
    }
}
