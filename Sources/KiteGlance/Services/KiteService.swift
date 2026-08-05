import Foundation
import CryptoKit
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

        var allHoldings: [Holding] = []
        var dayPnl: Decimal = 0
        var equityCurrent: Decimal = 0

        for h in equity {
            let qty = h.quantity + (h.t1_quantity ?? 0)
            guard qty > 0 else { continue }

            let (lastPrice, awaiting) = priced(h.last_price, h.average_price)

            // The `close > 0` guard matters: an unpriced or newly listed holding
            // reports close_price 0, and `last - 0` would book the entire
            // position as today's gain, poisoning the portfolio day total.
            let change: Decimal
            if let dayChange = h.day_change {
                change = dayChange
            } else if let close = h.close_price, close > 0 {
                change = h.last_price - close
            } else {
                change = 0
            }

            dayPnl += qty * change
            equityCurrent += qty * lastPrice

            allHoldings.append(Holding(
                symbol: h.tradingsymbol.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Unnamed holding"
                    : h.tradingsymbol,
                qty: qty,
                avgPrice: h.average_price,
                lastPrice: lastPrice,
                isMutualFund: false,
                awaitingPrice: awaiting,
                apiPnl: h.pnl
            ))
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

        for f in funds {
            guard f.quantity > 0 else { continue }

            var nav = f.last_price
            var apiPnl: Decimal? = f.pnl

            if let liveNavs,
               let symbol = f.tradingsymbol?.trimmingCharacters(in: .whitespaces),
               !symbol.isEmpty,
               let amfi = liveNavs[symbol],
               amfi > 0 {
                nav = amfi
                apiPnl = nil   // stale-NAV pnl cannot annotate a live NAV
            }

            let (lastPrice, awaiting) = priced(nav, f.average_price)

            allHoldings.append(Holding(
                symbol: f.fundName.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Awaiting allotment"
                    : f.fundName,
                qty: f.quantity,
                avgPrice: f.average_price,
                lastPrice: lastPrice,
                isMutualFund: true,
                awaitingPrice: awaiting,
                apiPnl: apiPnl
            ))
        }

        let prevClose = equityCurrent - dayPnl

        return PortfolioData(
            dayPnl: dayPnl,
            dayPnlPct: prevClose > 0 ? dayPnl / prevClose * 100 : 0,
            holdings: allHoldings
        )
    }

    /// A holding Kite has not priced yet is held at cost rather than marked to a
    /// zero it never quoted. Returns the price to use and whether it is a
    /// stand-in.
    private func priced(_ last: Decimal, _ avg: Decimal) -> (price: Decimal, awaiting: Bool) {
        let awaiting = last <= 0 && avg > 0
        return (awaiting ? avg : last, awaiting)
    }

    // MARK: - HTTP

    private func request<T: Decodable>(
        path: String,
        method: String,
        responseType: T.Type,
        extraHeaders: [String: String] = [:]
    ) async throws -> T {
        guard let token = accessToken, !apiKey.isEmpty else {
            throw KiteError("Not authenticated")
        }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = method
        urlRequest.setValue("3", forHTTPHeaderField: "X-Kite-Version")
        urlRequest.setValue("token \(apiKey):\(token)", forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders { urlRequest.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw KiteError("Invalid response")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            let payload = try? JSONDecoder().decode(KiteEnvelope.self, from: data)
            if payload?.error_type == "TokenException" {
                accessToken = nil
                try? await credentialVault.clearAccessToken()
                throw KiteError(payload?.message ?? "Session expired", isAuthFailure: true)
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

struct TokenResponse: Decodable {
    let data: SessionData?
    let message: String?
}

struct SessionData: Decodable {
    let access_token: String?
    let user_name: String?
}

struct EquityHolding: Decodable {
    let tradingsymbol: String
    let quantity: Decimal
    let t1_quantity: Decimal?
    let average_price: Decimal
    let last_price: Decimal
    let close_price: Decimal?
    let day_change: Decimal?
    let pnl: Decimal?
}

struct MFHolding: Decodable {
    /// Kite sends this as `fund`, not `fund_name`. Decoding the wrong key made
    /// every fund fall through to the "Awaiting allotment" placeholder.
    let fundName: String
    let tradingsymbol: String?
    let quantity: Decimal
    let average_price: Decimal
    let last_price: Decimal
    /// Kite's own P&L. The MF endpoint returns a literal 0 for holdings it has
    /// not computed, so a zero here is an absence, not a fact -- see PnlMath.
    let pnl: Decimal?

    enum CodingKeys: String, CodingKey {
        case fundName = "fund"
        case tradingsymbol, quantity, average_price, last_price, pnl
    }
}

struct Holding: Identifiable, Hashable {
    /// Stable across refreshes: a symbol identifies the same row from one fetch
    /// to the next. A fresh UUID per rebuild would make SwiftUI treat every
    /// refresh as a wholly new list, dropping row animation and hover state.
    var id: String { "\(isMutualFund ? "mf" : "eq"):\(symbol)" }

    let symbol: String
    let qty: Decimal
    let avgPrice: Decimal
    let lastPrice: Decimal
    let isMutualFund: Bool
    let awaitingPrice: Bool
    let apiPnl: Decimal?

    var invested: Decimal { PnlMath.invested(qty: qty, avgPrice: avgPrice) }

    var pnl: Decimal {
        PnlMath.pnl(qty: qty, avgPrice: avgPrice, lastPrice: lastPrice,
                    apiPnl: apiPnl, awaitingPrice: awaitingPrice)
    }

    var current: Decimal {
        PnlMath.current(qty: qty, avgPrice: avgPrice, lastPrice: lastPrice,
                        apiPnl: apiPnl, awaitingPrice: awaitingPrice)
    }

    var pnlPct: Decimal { PnlMath.pnlPct(pnl: pnl, invested: invested) }
}

struct PortfolioData {
    let dayPnl: Decimal
    let dayPnlPct: Decimal
    let holdings: [Holding]
}

struct KiteError: LocalizedError {
    let message: String
    /// Set when Kite rejected the session, so callers can prompt a re-login
    /// instead of string-matching the message text.
    let isAuthFailure: Bool

    init(_ message: String, isAuthFailure: Bool = false) {
        self.message = message
        self.isAuthFailure = isAuthFailure
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
