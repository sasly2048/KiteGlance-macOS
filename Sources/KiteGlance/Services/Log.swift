import Foundation
import os.log

enum LogLevel: Int, Comparable {
    case debug = 0, info = 1, warn = 2, error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

actor Log {
    static let shared = Log()

    private let logger = Logger(subsystem: "com.kiteglance", category: "general")
    private let fileLogger: FileLogger

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("KiteGlance/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("kiteglance.log")
        self.fileLogger = FileLogger(url: fileURL)
    }

    private var minimumLevel: LogLevel {
        ProcessInfo.processInfo.environment["KITEGLANCE_DEBUG"] == "1" ? .debug : .info
    }

    func debug(_ message: String) { log(.debug, message) }
    func info(_ message: String) { log(.info, message) }
    func warn(_ message: String) { log(.warn, message) }
    func error(_ message: String, error: Error? = nil) {
        var msg = message
        if let error { msg += " :: \(error)" }
        log(.error, msg)
    }

    private func log(_ level: LogLevel, _ message: String) {
        guard level >= minimumLevel else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "\(timestamp)  [\(level)]  \(message)"

        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warn: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }

        Task { await fileLogger.write(formatted) }
    }
}

actor FileLogger {
    private let url: URL
    private let maxBytes = 1_024 * 1_024

    init(url: URL) { self.url = url }

    func write(_ line: String) {
        do {
            try rotateIfNeeded()
            try (line + "\n").data(using: .utf8)?.write(to: url, options: [.atomic, .withoutOverwriting])
        } catch {
            // Silently ignore logging failures
        }
    }

    private func rotateIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size >= maxBytes else { return }

        let backup = url.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: url, to: backup)
    }
}