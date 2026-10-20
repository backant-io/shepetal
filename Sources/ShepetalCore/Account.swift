import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Sign-in, free trial and lifetime license against the account service (web/API.md on feat/web).
// These calls are the app's only network use: sign-in, the license check and checkout. Nothing here
// runs during dictation, and audio and text never go through it.

/// POST /api/device/start
public struct DeviceStart: Decodable, Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURIComplete: URL
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code"
        case verificationURIComplete = "verification_uri_complete", expiresIn = "expires_in", interval
    }
}

/// One answer of POST /api/device/token.
public enum TokenPoll: Equatable, Sendable {
    case pending, slowDown, expired, denied
    case granted(token: String, email: String)
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
    public var isServerError: Bool { status >= 500 }
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

    public func startDevice() async throws -> DeviceStart {
        let (status, data) = try await send("POST", "/api/device/start", json: [:])
        guard status == 200 else { throw Self.unexpected(status) }
        return try JSONDecoder().decode(DeviceStart.self, from: data)
    }

    public func pollToken(deviceCode: String) async throws -> TokenPoll {
        let (status, data) = try await send("POST", "/api/device/token", json: ["device_code": deviceCode])
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 200, let token = body["access_token"] as? String, !token.isEmpty {
            return .granted(token: token, email: body["email"] as? String ?? "")
        }
        if status == 400 {
            switch body["error"] as? String {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown
            case "expired_token": return .expired
            case "access_denied": return .denied
            default: break
            }
        }
        throw Self.unexpected(status)
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
        guard status == 200, let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let s = body["url"] as? String, let url = URL(string: s), DeviceFlow.isWebPage(url)
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

/// The device flow (RFC 8628): start, show the page, poll at the given interval until the user confirms.
public enum DeviceFlow {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    /// `open` gets the start reply (open its page, show its code). A network error while polling is retried
    /// until the code expires; slow_down adds 5 s to the interval, as RFC 8628 says.
    public static func signIn(_ client: AccountClient, open: @Sendable (DeviceStart) async -> Void,
                              sleep: Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                              now: @Sendable () -> Date = Date.init) async throws -> (token: String, email: String) {
        let start = try await client.startDevice()
        guard isWebPage(start.verificationURIComplete) else {
            throw AccountError("The account service sent a sign-in page that is not a web address")
        }
        let deadline = now().addingTimeInterval(TimeInterval(start.expiresIn))
        var interval = TimeInterval(max(1, start.interval))
        await open(start)
        while true {
            try await sleep(interval)
            try Task.checkCancellation()
            guard now() < deadline else { throw AccountError("The sign-in code expired. Try again.") }
            let reply: TokenPoll
            do { reply = try await client.pollToken(deviceCode: start.deviceCode) } catch is CancellationError {
                throw CancellationError()
            } catch let e as AccountError where !e.isServerError {
                throw e
            } catch {
                continue  // offline or a 5xx for a moment: keep polling until the code expires
            }
            switch reply {
            case .pending: continue
            case .slowDown: interval += 5
            case .expired: throw AccountError("The sign-in code expired. Try again.")
            case .denied: throw AccountError("Sign-in was cancelled in the browser")
            case let .granted(token, email): return (token, email)
            }
        }
    }

    /// Only https pages are opened, plus http on this Mac for a local copy of the service.
    public static func isWebPage(_ url: URL) -> Bool {
        url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? ""))
    }
}

/// What the user may do right now.
public enum Access: Equatable, Sendable {
    case signedOut
    case trial(daysLeft: Int)
    case lifetime
    case expired
    /// Signed in, but no good license check in the last 7 days (or none yet).
    case unchecked

    public var allowsDictation: Bool {
        switch self {
        case .trial, .lifetime: true
        case .signedOut, .expired, .unchecked: false
        }
    }

    /// One line for the menu and Home.
    public var summary: String {
        switch self {
        case .signedOut: "Not signed in"
        case let .trial(days): "Free trial: \(days) \(days == 1 ? "day" : "days") left"
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
    public static let signIn = "Sign in to start your free 30-day trial"
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

    public init(license: License? = nil, lastGoodCheck: Date? = nil, lastAttempt: Date? = nil) {
        self.license = license; self.lastGoodCheck = lastGoodCheck; self.lastAttempt = lastAttempt
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
    /// A license stays valid this long without reaching the service.
    public static let offlineGrace: TimeInterval = 7 * 86_400
    public static let checkEvery: TimeInterval = 86_400
    /// After a failed check, try again this much later.
    public static let retryAfterFailure: TimeInterval = 3_600

    public static func access(signedIn: Bool, state: AccountState, now: Date) -> Access {
        guard signedIn else { return .signedOut }
        guard let license = state.license, let checked = state.lastGoodCheck,
              now.timeIntervalSince(checked) <= offlineGrace else { return .unchecked }
        switch license.status {
        case .active: return .lifetime
        case .expired: return .expired
        case .trial:
            // The cached end date counts even offline: a trial does not outlive its end by staying offline.
            guard let end = license.trialEndsAt, end > now else { return .expired }
            return .trial(daysLeft: Int((end.timeIntervalSince(now) / 86_400).rounded(.up)))
        }
    }

    /// A check is due at launch (no attempt yet), 24 h after the last good one, or an hour after a failed one.
    public static func checkDue(state: AccountState, now: Date) -> Bool {
        guard let attempt = state.lastAttempt else { return true }
        let good = state.lastGoodCheck ?? .distantPast
        if attempt > good.addingTimeInterval(1) { return now.timeIntervalSince(attempt) >= retryAfterFailure }
        return now.timeIntervalSince(good) >= checkEvery
    }

    /// Folds a check result into the cache. A 401 signs out (the caller drops the token); a failed
    /// check keeps the cached license, so the 7-day grace counts from the last good check.
    public static func apply(_ result: Result<LicenseReply, Error>, to state: AccountState, now: Date) -> (AccountState, signedOut: Bool) {
        var s = state
        s.lastAttempt = now
        switch result {
        case let .success(.license(license)):
            s.license = license
            s.lastGoodCheck = now
            return (s, false)
        case .success(.unauthorized):
            return (AccountState(), true)
        case .failure:
            return (s, false)
        }
    }
}
