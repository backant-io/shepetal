import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Google sign-in, free trial and lifetime license against the account service (web/API.md on feat/web).
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

/// GET /api/license
public struct License: Codable, Equatable, Sendable {
    public var status: LicenseStatus
    public var trialEndsAt: Date?
    public var email: String

    public init(status: LicenseStatus, trialEndsAt: Date?, email: String) {
        self.status = status; self.trialEndsAt = trialEndsAt; self.email = email
    }

    /// What was paid for, nil for a trial or an expired license. The service has one paid kind today: "active",
    /// the one-time purchase that never expires (web/API.md), so it is the lifetime plan.
    public var plan: Plan? { status == .active ? .lifetime : nil }
}

/// A paid plan. A subscription would add `case subscription(paidThrough: Date)` from the license answer, and
/// `AccountPolicy.access` has to say how long it holds offline: the switch there does not compile until it does.
public enum Plan: Equatable, Sendable {
    /// Bought once: works offline for good.
    case lifetime
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
        return .license(License(status: s, trialEndsAt: ends, email: body["email"] as? String ?? ""))
    }

    /// The Stripe Checkout page for the lifetime license.
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
    case expired
    /// Signed in, but no license the service confirmed: none yet, a trial not checked in the last 7 days, or a cache
    /// whose seal does not match.
    case unchecked

    public var allowsDictation: Bool {
        switch self {
        case .trial, .lifetime: true
        case .signedOut, .expired, .unchecked: false
        }
    }

    /// One line for Home.
    public var summary: String {
        switch self {
        case .signedOut: "Not signed in"
        case let .trial(days): "Trial, \(days) \(days == 1 ? "day" : "days") left"
        case .lifetime: "Yours forever"
        case .expired: "Trial ended"
        case .unchecked: "License not checked"
        }
    }

    /// The text next to 🤫 when fn is pressed while dictation is off.
    public var blockedHint: String? {
        switch self {
        case .trial, .lifetime: nil
        case .signedOut: AccountText.signIn
        case .expired: AccountText.trialEnded
        case .unchecked: "Connect to the internet so Shepetal can check your license"
        }
    }
}

public enum AccountText {
    public static let signIn = "Sign in with Google to start your free 30-day trial"
    public static let trialEnded = "Trial ended: get Shepetal for $4.99"
    public static let buy = "Get Shepetal for $4.99 (lifetime, updates included)"
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
    private var sealedBytes: Data {
        let iso = ISO8601DateFormatter()
        let fields = ["shepetal-license-v1", license?.status.rawValue ?? "", license?.trialEndsAt.map(iso.string) ?? "",
                      lastGoodCheck.map(iso.string) ?? "", license?.email ?? ""]
        return Data(fields.joined(separator: "\n").utf8)
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
    public static let checkEvery: TimeInterval = 86_400
    /// After a failed check, try again this much later.
    public static let retryAfterFailure: TimeInterval = 3_600

    /// `token` is the account token, nil when signed out. Only a cache sealed with it counts.
    public static func access(token: String?, state: AccountState, now: Date) -> Access {
        guard let token else { return .signedOut }
        guard let license = state.license, state.isSealed(with: token) else { return .unchecked }
        switch license.plan {
        case .lifetime?: return .lifetime  // "Yours forever" and "Works offline", however long it is offline (#254)
        case nil: break  // a trial or an expired license: the offline grace below
        }
        guard let checked = state.lastGoodCheck, now.timeIntervalSince(checked) <= offlineGrace else { return .unchecked }
        // The cached end date counts even offline: a trial does not outlive its end by staying offline.
        guard license.status == .trial, let end = license.trialEndsAt, end > now else { return .expired }
        return .trial(daysLeft: Int((end.timeIntervalSince(now) / 86_400).rounded(.up)))
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
