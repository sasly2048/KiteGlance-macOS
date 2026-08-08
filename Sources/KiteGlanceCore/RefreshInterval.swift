import Foundation

/// How often the widget re-fetches, in minutes.
///
/// Zero means off; anything else is clamped into 1...60 on *read* rather than
/// on write. A value already persisted by an older build, or hand-edited in the
/// JSON, must not be able to schedule a timer every few milliseconds, and
/// clamping at the read is what guarantees that regardless of how the number
/// got there.
public enum RefreshInterval {
    public static let `default` = 5
    public static let minimum = 1
    public static let maximum = 60
    /// Offered in the Settings picker. Off is presented separately.
    public static let choices = [1, 2, 5, 10, 15, 30, 60]

    /// The stored value made safe to schedule on. `nil` means auto-refresh is
    /// off, which is a real choice, not a failure to configure.
    public static func effective(_ stored: Int) -> Int? {
        guard stored != 0 else { return nil }
        return min(max(stored, minimum), maximum)
    }
}
