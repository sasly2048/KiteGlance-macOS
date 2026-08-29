@preconcurrency import Foundation
import Network
import AppKit
import os.log

/// Minimal loopback HTTP responder that captures Kite's OAuth redirect.
/// The Kite app's Redirect URL must be `http://127.0.0.1:5173/callback`.
///
/// `@preconcurrency` on `Foundation` lets us import `Network` without
/// pulling every closure type into the Swift 6 strict-concurrency
/// checker. The actor isolation in the rest of the file is explicit
/// (`@MainActor` on the AppDelegate-equivalent types, actor for
/// `LoginServer` itself), and the network callbacks hop onto the actor
/// with `Task { await self.x() }` so the only thing crossing isolation is
/// the Task body, not the callback parameter itself.
actor LoginServer {
    static let port: NWEndpoint.Port = 5173
    private let logger = Logger(subsystem: "com.kiteglance", category: "LoginServer")

    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    /// Buffered bytes per connection. A browser can split the request across TCP
    /// segments, so a single read may truncate the query string and drop
    /// `request_token`.
    private var buffers: [ObjectIdentifier: Data] = [:]

    private let donePage = """
        <!doctype html><html><head><meta charset="utf-8"><title>KiteGlance</title>
        <style>
        body{margin:0;height:100vh;display:grid;place-items:center;background:#0F1318;
             color:#fff;font-family:-apple-system,"SF Pro Text",system-ui,sans-serif}
        .t{font-size:44px;color:#00D084}
        p{color:#A8B3BE}
        </style></head><body><div style="text-align:center">
        <div class="t">&#10003;</div><h2>Connected to Kite</h2>
        <p>You can close this tab and return to the widget.</p>
        </div></body></html>
        """

    func captureRequestToken(loginURL: String, timeout: TimeInterval = 300) async throws -> String {
        // Loopback only. Binding all interfaces would expose the callback -- and
        // the request_token in its query string -- to the local network.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: Self.port)
        } catch {
            throw LoginError("Port \(Self.port.rawValue) is busy. Close whatever is using it and try again.")
        }
        self.listener = listener

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    Task { await self.handleState(state, loginURL: loginURL) }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    Task { await self.accept(connection) }
                }

                listener.start(queue: .main)

                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    await self?.finish(.failure(LoginError("Login timed out. Please try again.")))
                }
            }
        } onCancel: {
            Task { await self.finish(.failure(CancellationError())) }
        }
    }

    private func handleState(_ state: NWListener.State, loginURL: String) {
        switch state {
        case .ready:
            logger.info("Login server listening on port \(Self.port.rawValue, privacy: .public)")
            if let url = URL(string: loginURL) {
                NSWorkspace.shared.open(url)
            } else {
                finish(.failure(LoginError("Could not build the Kite login URL. Check your API key.")))
            }
        case .failed(let error):
            finish(.failure(LoginError("Login server failed: \(error.localizedDescription)")))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection)
    }

    /// `NWConnection.receive`'s completion handler runs on `queue: .main` and
    /// must be `@Sendable`. Capturing `[weak self]` (an actor type) directly
    /// would be a Sendable violation under Swift 6 strict concurrency, so
    /// instead the handler hops onto the actor's executor with a `Task` --
    /// which is the documented pattern for bridging non-isolated callbacks
    /// into an actor's isolation.
    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, error in
            Task {
                await self.handleChunk(data, isComplete: isComplete, error: error, connection: connection)
            }
        }
    }

    private func handleChunk(_ data: Data?, isComplete: Bool, error: NWError?, connection: NWConnection) {
        let key = ObjectIdentifier(connection)

        guard error == nil else {
            buffers[key] = nil
            connection.cancel()
            return
        }

        if let data, !data.isEmpty {
            buffers[key, default: Data()].append(data)
        }

        let buffered = buffers[key] ?? Data()

        // `String(data:encoding:)` is the safe version. The previous code used
        // `String(decoding:as:)` which throws on non-UTF-8 input -- some HTTP
        // clients send Latin-1 or other encodings, and the throw would crash
        // the Task (and the actor with it). A best-effort decode is the
        // right behaviour here: a malformed request is dropped, the
        // connection gets a 200 and a tiny page, and the next browser
        // request (always in the same connection) is what carries the
        // token anyway.
        let request = String(data: buffered, encoding: .utf8)
            ?? String(data: buffered, encoding: .isoLatin1)

        // Keep reading until the header block is complete or the request line is
        // unambiguously whole -- matching the Windows original, which reads in a
        // loop for exactly this reason.
        let headersComplete = request.contains("\r\n\r\n")
        let requestLineComplete = request.contains("\r\n") && request.contains(" HTTP/")

        guard headersComplete || requestLineComplete || isComplete || buffered.count >= 16384 else {
            receive(on: connection)
            return
        }

        buffers[key] = nil

        guard let firstLine = request.split(separator: "\r\n").first,
              let path = firstLine.split(separator: " ")[safe: 1],
              path.hasPrefix("/callback") else {
            // Browsers also request /favicon.ico here. Ignore anything that is
            // not the callback rather than failing the whole login.
            connection.cancel()
            return
        }

        let query = parseQuery(String(path))
        let token = query["request_token"]
        let status = query["status"]

        let body = Data(donePage.utf8)
        // Build the header as a plain array of bytes to avoid the multi-line
        // string literal's CR+LF confusion (raw source line endings + escape
        // sequences producing \r\r\n instead of the required \r\n).
        let headerString = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let head = Data(headerString.utf8)

        connection.send(content: head + body, completion: .contentProcessed { _ in
            connection.cancel()
            // The completion handler runs on the queue we passed to
            // `connection.start(queue:)` -- in our case `.main` -- and is
            // not actor-isolated, so a `[weak self]` capture would be a
            // Sendable violation. Hop through a `Task` instead, which is the
            // pattern the rest of the file uses.
            Task { [weak self] in
                guard let self else { return }
                if status == "success", let token, !token.isEmpty {
                    await self.finish(.success(token))
                } else {
                    await self.finish(.failure(LoginError("Login was cancelled or rejected by Kite.")))
                }
            }
        })
    }

    /// Single exit point. Resuming a `CheckedContinuation` twice is a crash, and
    /// the timeout, the callback, and a listener failure all race to finish --
    /// so whoever gets here first wins and the rest become no-ops. Actor
    /// isolation makes that check atomic; the original passed an `inout Bool`
    /// into escaping closures, which is both a data race and not legal Swift.
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil

        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()      // the original leaked the listener on success
        listener = nil
        buffers.removeAll()

        continuation.resume(with: result)
    }

    private func parseQuery(_ path: String) -> [String: String] {
        guard let q = path.firstIndex(of: "?") else { return [:] }

        var result: [String: String] = [:]
        for pair in path[path.index(after: q)...].split(separator: "&") {
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
