import Foundation
import os.log

actor KiteService {
    private let baseURL = URL(string: "https://api.kite.trade")!
    private let credentialVault = CredentialVault()
    private let amfiNav = AmfiNavService()
    private let logger = Logger(subsystem: "com.kiteglance", category: "KiteService")

    private var apiKey: String = ""
    private var accessToken: String?
    private let refreshGate = AsyncSemaphore(value: 1)

    var usingStaleFundNavs = false

    init() {
        Task { await loadCredentials() }
    }

    private func loadCredentials() async {
        if let creds = await credentialVault.load() {
            apiKey = creds.apiKey
            accessToken = creds.accessToken
        }
    }

    func reloadCredentials() async {
        await loadCredentials()
    }

    var loginURL: String {
        "https://kite.zerodha.com/connect/login?v=3&api_key=\(apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
    }

    func isAuthenticated() async -> Bool {
        guard !apiKey.isEmpty, accessToken != nil else { return false }
        do {
            _ = try await request(path: "/user/profile", method: "GET", responseType: UserProfile.self)
            return true
        } catch {
            return false
        }
    }

    func authenticate(requestToken: String) async throws {
        guard let creds = await credentialVault.load() else {
            throw KiteError("API secret not found. Re-enter in Settings.")
        }

        let checksum = sha256(apiKey + requestToken + creds.apiSecret)
        let params = [
            "api_key": apiKey,
            "request_token": requestToken,
            "checksum": checksum
        ]

        let response: TokenResponse = try await request(
            path: "/session/token",
            method: "POST",
            body: params,
            responseType: TokenResponse.self,
            extraHeaders: ["X-Kite-Version": "3"]
        )

        guard let token = response.data?.access_token else {
            throw KiteError(response.message ?? "Login failed. Check your API secret.")
        }

        accessToken = token
        try await credentialVault.updateAccessToken(token)
    }

    func getPortfolio() async throws -> PortfolioData {
        await refreshGate.wait()
        defer { refreshGate.signal() }

        guard let token = accessToken, !apiKey.isEmpty else {
            throw KiteError("Not authenticated")
        }

        async let equityResponse: [EquityHolding] = request(path: "/portfolio/holdings", method: "GET")
        async let mfResponse: [MFHolding] = request(path: "/mf/holdings", method: "GET")

        let equity = (try? await equityResponse) ?? []
        let funds = (try? await mfResponse) ?? []

        var allHoldings: [Holding] = []
        var dayPnl: Decimal = 0
        var equityCurrent: Decimal = 0

        for h in equity {
            let qty = h.quantity + (h.t1_quantity ?? 0)
            guard qty > 0 else { continue }

            let lastPrice = priced(h.last_price, h.average_price, out: &[])
            let change = h.day_change ?? (h.close_price.map { h.last_price - $0 } ?? 0)
            dayPnl += qty * change
            equityCurrent += qty * lastPrice

            allHoldings.append(Holding(
                symbol: h.tradingsymbol.isEmpty ? "Unnamed holding" : h.tradingsymbol,
                qty: qty,
                avgPrice: h.average_price,
                lastPrice: lastPrice,
                isMutualFund: false,
                awaitingPrice: h.last_price <= 0 && h.average_price > 0,
                apiPnl: h.pnl
            ))
        }

        let liveNavs = funds.isEmpty ? nil : await amfiNav.getAllNavs()
        usingStaleFundNavs = !funds.isEmpty && !(amfiNav.hasLiveData || liveNavs != nil)

        for f in funds {
            guard f.quantity > 0 else { continue }

            var kiteNav = f.last_price
            var apiPnl: Decimal? = f.pnl

            if let liveNavs,
               !f.tradingsymbol.isEmpty,
               let amfiNav = liveNavs[f.tradingsymbol.trimmingCharacters(in: .whitespaces)],
               amfiNav > 0 {
                kiteNav = amfiNav
                apiPnl = nil
            }

            var awaiting = false
            let lastPrice = priced(kiteNav, f.average_price, out: &awaiting)

            allHoldings.append(Holding(
                symbol: f.fund_name.isEmpty ? "Awaiting allotment" : f.fund_name,
                qty: f.quantity,
                avgPrice: f.average_price,
                lastPrice: lastPrice,
                isMutualFund: true,
                awaitingPrice: awaiting,
                apiPnl: apiPnl
            ))
        }

        let prevClose = equityCurrent - dayPnl
        let dayPnlPct = prevClose > 0 ? dayPnl / prevClose * 100 : 0

        return PortfolioData(
            dayPnl: dayPnl,
            dayPnlPct: dayPnlPct,
            holdings: allHoldings
        )
    }

    private func priced(_ last: Decimal, _ avg: Decimal, out awaiting: inout Bool) -> Decimal {
        awaiting = last <= 0 && avg > 0
        return awaiting ? avg : last
    }

    // MARK: - HTTP

    private func request<T: Decodable>(
        path: String,
        method: String,
        body: [String: String]? = nil,
        responseType: T.Type,
        extraHeaders: [String: String] = [:]
    ) async throws -> T {
        guard let token = accessToken, !apiKey.isEmpty else {
            throw KiteError("Not authenticated")
        }

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("3", forHTTPHeaderField: "X-Kite-Version")
        request.setValue("token \(apiKey):\(token)", forHTTPHeaderField: "Authorization")

        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }

        if let body {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
                .joined(separator: "&").data(using: .utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KiteError("Invalid response")
        }

        if httpResponse.statusCode == 403 || httpResponse.statusCode == 401 {
            let payload = try? JSONDecoder().decode(KiteResponse<String>.self, from: data)
            if payload?.error_type == "TokenException" {
                accessToken = nil
                try? await credentialVault.clearAccessToken()
                throw KiteError(payload?.message ?? "Session expired")
            }
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let payload = try? JSONDecoder().decode(KiteResponse<String>.self, from: data)
            throw KiteError(payload?.message ?? "Request failed (\(httpResponse.statusCode))")
        }

        let wrapper = try JSONDecoder().decode(KiteResponse<T>.self, from: data)
        guard let data = wrapper.data else {
            throw KiteError("Empty response")
        }
        return data
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Models

struct KiteResponse<T: Decodable>: Decodable {
    let status: String?
    let message: String?
    let error_type: String?
    let data: T?
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
    let fund_name: String
    let tradingsymbol: String?
    let quantity: Decimal
    let average_price: Decimal
    let last_price: Decimal
    let pnl: Decimal?
}

struct Holding: Identifiable {
    let id = UUID()
    let symbol: String
    let qty: Decimal
    let avgPrice: Decimal
    let lastPrice: Decimal
    let isMutualFund: Bool
    let awaitingPrice: Bool
    let apiPnl: Decimal?

    var invested: Decimal { qty * avgPrice }

    var pnl: Decimal {
        if awaitingPrice { return 0 }
        if let apiPnl, apiPnl != 0 { return apiPnl }
        return (lastPrice - avgPrice) * qty
    }

    var current: Decimal {
        if awaitingPrice { return invested }
        if let apiPnl, apiPnl != 0 { return invested + apiPnl }
        return qty * lastPrice
    }

    var pnlPct: Decimal { invested > 0 ? pnl / invested * 100 : 0 }
}

struct PortfolioData {
    let dayPnl: Decimal
    let dayPnlPct: Decimal
    let holdings: [Holding]
}

struct KiteError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Simple async semaphore
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { self.value = value }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            value += 1
        }
    }
}

import CryptoKit