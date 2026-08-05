import Foundation
import Network
import os.log

actor LoginServer {
    static let port: NWEndpoint.Port = 5173
    private let logger = Logger(subsystem: "com.kiteglance", category: "LoginServer")

    private let donePage = """
        <!doctype html><html><head><meta charset="utf-8"><title>KiteGlance</title>
        <style>
        body{margin:0;height:100vh;display:grid;place-items:center;background:#0F1318;
             color:#fff;font-family:"Segoe UI",system-ui,sans-serif}
        .t{font-size:44px;color:#00D084}
        p{color:#A8B3BE}
        </style></head><body><div style="text-align:center">
        <div class="t">✓</div><h2>Connected to Kite</h2>
        <p>You can close this tab and return to the widget.</p>
        </div></body></html>
        """

    func captureRequestToken(loginURL: String, timeout: TimeInterval = 300) async throws -> String {
        let listener = try NWListener(using: .tcp, on: Self.port)

        return try await withCheckedThrowingContinuation { continuation in
            var hasResponded = false

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.logger.info("Login server listening on port \(Self.port.rawValue)")
                    NSWorkspace.shared.open(URL(string: loginURL)!)
                case .failed(let error):
                    if !hasResponded {
                        hasResponded = true
                        continuation.resume(throwing: LoginError("Port \(Self.port.rawValue) is busy. Close whatever is using it and try again."))
                    }
                default: break
                }
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                self.handleConnection(connection, continuation: continuation, hasResponded: &hasResponded)
            }

            listener.start(queue: .main)

            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !hasResponded {
                    hasResponded = true
                    listener.cancel()
                    continuation.resume(throwing: LoginError("Login timed out. Please try again."))
                }
            }
        }
    }

    private func handleConnection(_ connection: NWConnection, continuation: CheckedContinuation<String, Error>, hasResponded: inout Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, error in
            guard !hasResponded, let data, !data.isEmpty else { return }

            let request = String(decoding: data, as: UTF8.self)
            guard let firstLine = request.split(separator: "\r\n").first,
                  let path = firstLine.split(separator: " ")[safe: 1],
                  path.hasPrefix("/callback") else { return }

            let query = self.parseQuery(String(path))
            let token = query["request_token"]
            let status = query["status"]

            let responseBody = Data(self.donePage.utf8)
            let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(responseBody.count)\r
                Connection: close\r
                \r
                """

            var responseData = Data(response.utf8)
            responseData.append(responseBody)

            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
                if status == "success", let token, !token.isEmpty {
                    hasResponded = true
                    continuation.resume(returning: token)
                } else {
                    hasResponded = true
                    continuation.resume(throwing: LoginError("Login was cancelled or rejected by Kite."))
                }
            })
        }
    }

    private func parseQuery(_ path: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let q = path.firstIndex(of: "?") else { return result }
        let queryString = path[path.index(after: q)...]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].removingPercentEncoding ?? String(parts[0])
            let value = parts[1].removingPercentEncoding ?? String(parts[1])
            result[key] = value
        }
        return result
    }
}

struct LoginError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}