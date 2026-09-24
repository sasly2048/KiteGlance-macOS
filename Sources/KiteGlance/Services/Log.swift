import Foundation
import os.log
import KiteGlanceCore

/// `LogLevel` and the template renderer live in `KiteGlanceCore` so
/// the test target can reach them. The actor here is the side-effecting
/// sink: `os.log`, the rotating text file, and the optional JSONL file.

actor AppLog {
    static let shared = AppLog()

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

    /// Structured entry. A free-form `messageTemplate` with `{Name}` holes
    /// is rendered against the `properties` map. The rendered string goes
    /// to the human-readable log; the structured record (template +
    /// properties + level + timestamp) goes to the JSONL sink, which is
    /// the right place to grep when a user reports a specific failure
    /// mode. Mirrors the Windows `Log.WriteStructured` / `Log.Render`.
    func structured(
        _ level: LogLevel,
        _ messageTemplate: String,
        properties: [String: String] = [:]
    ) {
        let rendered = KiteGlanceCore.Log.render(template: messageTemplate, properties: properties)
        log(level, rendered)

        // JSONL is opt-in: enabling it in production means a sensitive
        // properties map (e.g. account id) lands on disk on every line.
        // Following the Windows `WriteStructured` opt-in via env var.
        guard ProcessInfo.processInfo.environment["KITEGLANCE_STRUCTURED_LOG"] == "1" else { return }
        let record = StructuredRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            level: String(describing: level),
            template: messageTemplate,
            properties: properties
        )
        if let data = try? JSONEncoder().encode(record),
           let json = String(data: data, encoding: .utf8) {
            Task { await fileLogger.writeStructured(json) }
        }
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

    /// Appends. `Data.write(options: .withoutOverwriting)` -- what this used to
    /// do -- *fails* when the file exists, so exactly one line was ever written
    /// and every later call threw into the empty catch, making rotation below
    /// unreachable. A file handle seeked to the end is the actual append.
    func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }

        do {
            try rotateIfNeeded()

            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
                return
            }

            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // A logger that throws is worse than no logger. Give up silently.
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

    /// Appends a JSONL line. Same rotation policy as the human-readable
    /// log, but a different file (`kiteglance.jsonl`) so the two can be
    /// shipped and parsed independently. Opt-in: only written when
    /// `KITEGLANCE_STRUCTURED_LOG=1` so a default install does not produce
    /// the more verbose file.
    func writeStructured(_ line: String) {
        let jsonlURL = url.deletingLastPathComponent().appendingPathComponent("kiteglance.jsonl")
        guard let data = (line + "\n").data(using: .utf8) else { return }

        do {
            try rotateIfNeeded(at: jsonlURL)

            if !FileManager.default.fileExists(atPath: jsonlURL.path) {
                try data.write(to: jsonlURL, options: .atomic)
                return
            }

            let handle = try FileHandle(forWritingTo: jsonlURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Silent: a logger that throws is worse than no logger.
        }
    }

    private func rotateIfNeeded(at jsonlURL: URL) throws {
        guard FileManager.default.fileExists(atPath: jsonlURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlURL.path),
              let size = attrs[.size] as? Int64, size >= maxBytes else { return }

        let backup = jsonlURL.deletingPathExtension().appendingPathExtension("jsonl.1")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: jsonlURL, to: backup)
    }
}

/// JSONL record. `properties` is intentionally `[String: String]`: a
/// strongly-typed schema would require a code change every time a new
/// log site was added, which is the opposite of the point of structured
/// logging.
struct StructuredRecord: Codable {
    let timestamp: String
    let level: String
    let template: String
    let properties: [String: String]
}
