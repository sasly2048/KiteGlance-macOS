import Foundation

/// The `Log` actor lives in the executable target because it owns the
/// `os.log` and `FileLogger` sinks. The pure-functional parts of it --
/// the level enum and the message-template renderer -- are pure
/// functions with no dependencies on AppKit or os.log, so they live
/// here in `KiteGlanceCore` where the test target can reach them.
///
/// `LogLevel` is the same enum the executable's `Log` actor uses. The
/// duplicate definition is intentional: the test target cannot import
/// the executable, and the rendering rules depend only on the raw
/// value, which is shared.
public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info = 1, warn = 2, error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum Log {
    /// Renders `{Name}` holes against the properties map. Unknown holes
    /// are left as the literal `{Name}` so a missing value is visible
    /// in the log line instead of being silently dropped. Mirrors the
    /// Windows `Log.Render` from the 1.5.0 audit.
    public static func render(template: String, properties: [String: String]) -> String {
        var output = template
        for (name, value) in properties {
            output = output.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return output
    }
}
