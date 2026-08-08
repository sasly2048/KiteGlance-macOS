import Foundation
import CryptoKit
import KiteGlanceCore
import os.log

actor KiteService {
    private let baseURL = URL(string: "https://api.kite.trade")!
    private let credentialVault = CredentialVault()
    private let amfiNav = AmfiNavService()
    private let logger = Logger(subsystem: "com.kiteglance", category: "KiteService")

    private var apiKey: String = ""
    private var accessToken: String?
    private var didLoadCredentials = false
    private let refreshGate = AsyncSemaphore(value: 1)

    private(set) var usingStaleFundNavs = false

    /// Credentials load lazily on first use rather than in `init`. A
    /// fire-and-forget `Task` in the initializer races every caller: whoever
    /// reads `apiKey` first may see an empty string and show the "connect"
    /// overlay to an already-configured user. The Windows original loads at the
    /// call site (`_accessToken ??= _vault.GetAccessToken()`) for the same
    /// reason.
    private func ensureCredentialsLoaded() async {
        guard !didLoadCredentials else { return }
        didLoadCredentials = true
        await loadCredentials()
    }

    private func loadCredentials() async {
        if let creds = await credentialVault.load() {
            apiKey = creds.apiKey
            accessToken = creds.accessToken
        }
    }

    func reloadCredentials() async {
        didLoadCredentials = true
        await loadCredentials()
    }

    /// Whether an API key is configured at all. Distinguishes "never set up"
    /// from "set up but signed out", which drive different overlays.
    func hasApiKey() async -> Bool {
        await ensureCredentialsLoaded()
        return !apiKey.isEmpty
    }

    var loginURL: String {
        get async {
            await ensureCredentialsLoaded()
            let encoded = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return "https://kite.zerodha.com/connect/login?v=3&api_key=\(encoded)"
        }
    }

    func isAuthenticated() async -> Bool {
        await ensureCredentialsLoaded()
        guard !apiKey.isEmpty, accessToken != nil else { return false }
        do {
            _ = try await request(path: "/user/profile", method: "GET", responseType: UserProfile.self)
            return true
        } catch {
            return false
        }
    }

    func authenticate(requestToken: String) async throws {
        await ensureCredentialsLoaded()

        guard let creds = await credentialVault.load() else {
            throw KiteError("API secret not found. Re-enter in Settings.")
        }

        let checksum = sha256(apiKey + requestToken + creds.apiSecret)
        let params = [
            "api_key": apiKey,
            "request_token": requestToken,
            "checksum": checksum
        ]

        // The session endpoint is the one call made without an access token --
        // it is what mints one -- so it bypasses `request(...)`'s auth guard.
        let response = try await sessionRequest(path: "/session/token", body: params)

        guard let token = response.data?.access_token else {
            throw KiteError(response.message ?? "Login failed. Check your API secret.")
        }

        accessToken = token
        try await credentialVault.updateAccessToken(token)
    }

    func getPortfolio() async throws -> PortfolioData {
        await refreshGate.wait()
        defer { refreshGate.signalFromDefer() }

        await ensureCredentialsLoaded()

        guard accessToken != nil, !apiKey.isEmpty else {
            throw KiteError("Not authenticated")
        }

        let equity: [EquityHolding] = try await request(
            path: "/portfolio/holdings",
            method: "GET",
            responseType: [EquityHolding].self
        )

        // MF scope may simply not be enabled on the Kite app; that is a normal,
        // expected reason to have no funds. An expired session, however, must
        // propagate -- degrading it to "no funds" would hide the real problem
        // and leave the user staring at an equity-only portfolio.
        var funds: [MFHolding] = []
        do {
            funds = try await request(
                path: "/mf/holdings",
                method: "GET",
                responseType: [MFHolding].self
            )
        } catch let error as KiteError where error.isAuthFailure {
            throw error
        } catch {
            logger.warning("MF holdings fetch failed (\(error.localizedDescription, privacy: .public)); showing equity only")
        }

        // Kite's /mf/holdings last_price is a stale settlement NAV -- verified
        // 1-3 percent away from the live NAV Coin itself displays. AMFI is the
        // official source both derive from, keyed by ISIN, which is exactly what
        // Kite uses as the MF tradingsymbol. Override wherever we can; fall back
        // to Kite's figure when AMFI is unreachable or lacks the ISIN.
        let liveNavs: [String: Decimal]? = funds.isEmpty ? nil : await amfiNav.getAllNavs()

        // If we hold funds but AMFI never gave us live data, the NAVs below are
        // Kite's stale settlement figures. Record it so the UI can be honest.
        let amfiWasLive = await amfiNav.hasLiveData
        usingStaleFundNavs = !funds.isEmpty && !amfiWasLive

        // The arithmetic itself lives in KiteGlanceCore, where it can be unit
        // tested against literal holdings instead of a live HTTP call.
        return PortfolioAssembler.assemble(equity: equity, funds: funds, liveNavs: liveNavs)
    }

    /// Daily closes for an instrument, most recent last.
    ///
    /// Historical data is a paid Kite subscription; an account without it gets a
    /// 403 / `PermissionException`, surfaced as `isSubscriptionFailure` so the
    /// caller can fall back to the locally accumulated series instead of
    /// prompting for a re-login.
    func historicalCloses(instrumentToken: String, days: Int = 40) async throws -> [Double] {
        await ensureCredentialsLoaded()

        let end = Date()
        let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: end) ?? end

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Kolkata")

        // The query goes through `query:`, not the path: `request` builds its URL
        // with `appendingPathComponent`, which would percent-escape the `?` and
        // turn the whole thing into one nonsense path segment.
        let candles = try await request(
            path: "/instruments/historical/\(instrumentToken)/day",
            method: "GET",
            responseType: HistoricalCandles.self,
            query: [
                "from": formatter.string(from: start),
                "to": formatter.string(from: end)
            ]
        )

        // Each candle is [timestamp, open, high, low, close, volume]; index 4 is
        // the close, and anything shorter is malformed rather than fatal.
        return candles.candles.compactMap { candle -> Double? in
            guard candle.count > 4 else { return nil }
            return candle[4].doubleValue
        }
    }

    // MARK: - HTTP

    private func request<T: Decodable>(
        path: String,
        method: String,
        responseType: T.Type,
        extraHeaders: [String: String] = [:],
        query: [String: String] = [:]
    ) async throws -> T {
        guard let token = accessToken, !apiKey.isEmpty else {
            throw KiteError("Not authenticated")
        }

        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            url = components?.url ?? url
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("3", forHTTPHeaderField: "X-Kite-Version")
        urlRequest.setValue("token \(apiKey):\(token)", forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders { urlRequest.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw KiteError("Invalid response")
        }

        ApiDump.write(data, path: path)

        if http.statusCode == 401 || http.statusCode == 403 {
            let payload = try? JSONDecoder().decode(KiteEnvelope.self, from: data)
            if payload?.error_type == "TokenException" {
                accessToken = nil
                try? await credentialVault.clearAccessToken()
                throw KiteError(payload?.message ?? "Session expired", isAuthFailure: true)
            }
            // A valid session asking for an endpoint the account does not pay
            // for -- historical data, chiefly. Signing in again would not help,
            // so this must not be reported as an auth failure.
            if payload?.error_type == "PermissionException" {
                throw KiteError(
                    payload?.message ?? "Not subscribed",
                    isSubscriptionFailure: true
                )
            }
            throw KiteError(payload?.message ?? "Not authorized", isAuthFailure: true)
        }

        guard (200...299).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(KiteEnvelope.self, from: data)
            throw KiteError(payload?.message ?? "Request failed (\(http.statusCode))")
        }

        let wrapper = try JSONDecoder().decode(KiteResponse<T>.self, from: data)
        guard let payload = wrapper.data else {
            throw KiteError("Empty response")
        }
        return payload
    }

    /// The token-minting call. Unlike every other endpoint it authenticates with
    /// a checksum instead of a bearer token.
    private func sessionRequest(path: String, body: [String: String]) async throws -> TokenResponse {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("3", forHTTPHeaderField: "X-Kite-Version")
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        urlRequest.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw KiteError("Invalid response")
        }

        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard (200...299).contains(http.statusCode) else {
            throw KiteError(decoded?.message ?? "Login failed (\(http.statusCode))")
        }
        guard let decoded else {
            throw KiteError("Could not read Kite's login response.")
        }
        return decoded
    }

    private func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Debug dump

/// `KITEGLANCE_DEBUG=1` dumps raw API responses to
/// `~/Library/Application Support/KiteGlance/api-dump.json`. Field names in
/// Kite's API have shifted across versions; this exists so the truth can be
/// read instead of guessed at -- the `fund` vs `fund_name` bug is exactly what
/// it is for.
enum ApiDump {
    static let isEnabled = ProcessInfo.processInfo.environment["KITEGLANCE_DEBUG"] == "1"

    static var url: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("KiteGlance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("api-dump.json")
    }

    /// The dump contains the user's id, email and full holdings in plaintext.
    /// It exists only to diagnose API shape, so a non-debug launch deletes any
    /// leftover from a previous debug session: the sensitive file never
    /// outlives the debugging it was created for.
    static func purgeIfDisabled() {
        guard !isEnabled else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func write(_ data: Data, path: String) {
        guard isEnabled else { return }

        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        let entry = "// \(path) @ \(Date())\n\(body)\n\n"
        guard let encoded = entry.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: encoded)
        } else {
            try? encoded.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Models

struct KiteResponse<T: Decodable>: Decodable {
    let status: String?
    let message: String?
    let error_type: String?
    let data: T?
}

/// Error envelope, decoded when the payload shape is unknown or irrelevant.
struct KiteEnvelope: Decodable {
    let status: String?
    let message: String?
    let error_type: String?
}

struct UserProfile: Decodable {
    let user_id: String?
    let user_name: String?
}

/// `/instruments/historical` returns candles as heterogeneous arrays --
/// `["2026-08-07T00:00:00+0530", 1512.0, 1530.4, 1508.0, 1526.6, 41235]` -- so
/// the elements decode through a small any-scalar box rather than as `[Double]`,
/// which would throw on the leading timestamp string.
struct HistoricalCandles: Decodable {
    let candles: [[CandleValue]]
}

enum CandleValue: Decodable {
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .text((try? container.decode(String.self)) ?? "")
        }
    }

    /// `nil` for the timestamp, so a malformed candle contributes no point
    /// rather than a zero that would collapse the chart's range.
    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

struct TokenResponse: Decodable {
    let data: SessionData?
    let message: String?
}

struct SessionData: Decodable {
    let access_token: String?
    let user_name: String?
}

struct KiteError: LocalizedError {
    let message: String
    /// Set when Kite rejected the session, so callers can prompt a re-login
    /// instead of string-matching the message text.
    let isAuthFailure: Bool
    /// Set when the endpoint exists but this account does not subscribe to it --
    /// historical data is a paid add-on. Distinct from `isAuthFailure`: the
    /// session is perfectly valid, so prompting for a re-login would be wrong.
    let isSubscriptionFailure: Bool

    init(_ message: String, isAuthFailure: Bool = false, isSubscriptionFailure: Bool = false) {
        self.message = message
        self.isAuthFailure = isAuthFailure
        self.isSubscriptionFailure = isSubscriptionFailure
    }

    var errorDescription: String? { message }
}

/// A one-permit gate so two refreshes never overlap. Cancellation-aware: a
/// cancelled waiter must not leave its continuation orphaned, which would close
/// the gate permanently and freeze every later refresh.
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(value: Int) { self.value = value }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }

        let id = UUID()
        try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }

    func signal() {
        if let entry = waiters.first {
            waiters.removeValue(forKey: entry.key)
            entry.value.resume()
        } else {
            value += 1
        }
    }

    /// `defer` cannot `await`, so the gate is released via a detached hop.
    nonisolated func signalFromDefer() {
        Task { await signal() }
    }
}
