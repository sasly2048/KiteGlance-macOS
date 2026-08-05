import Foundation

public enum BackdropMode: String, CaseIterable, Codable, Sendable {
    case timeOfDay = "Time of Day"
    case rotate = "Rotate"
    /// `static` is a Swift keyword, so the case name needs backticks.
    case `static` = "Graphite (Static)"
    case custom = "Custom"
}

/// The eight pre-rendered mesh gradients, two per phase of the day.
public enum BackdropImage: String, CaseIterable, Sendable {
    case dawn = "backdrop-dawn"
    case sunrise = "backdrop-sunrise"
    case day = "backdrop-day"
    case noon = "backdrop-noon"
    case dusk = "backdrop-dusk"
    case evening = "backdrop-evening"
    case night = "backdrop-night"
    case midnight = "backdrop-midnight"

    // `allCases` is synthesized by CaseIterable in declaration order, which is
    // already day order. Redeclaring it conflicted with that conformance.

    public var displayName: String {
        switch self {
        case .dawn: "Dawn"
        case .sunrise: "Sunrise"
        case .day: "Morning"
        case .noon: "Noon"
        case .dusk: "Dusk"
        case .evening: "Evening"
        case .night: "Night"
        case .midnight: "Midnight"
        }
    }
}

/// Decides which backdrop the widget should show right now, given the mode and
/// the clock. Pure decision logic -- no AppKit, no file IO -- so the time
/// boundaries can be unit tested like the P&L math is.
public struct BackdropService {
    public static func pick(mode: BackdropMode, date: Date = Date()) -> BackdropImage {
        switch mode {
        case .timeOfDay: byHour(date)
        case .rotate: byRotation(date)
        // Custom mode is not answered here -- the caller uses the user's file.
        case .static, .custom: .day
        }
    }

    /// Dawn 05-08, day 08-17, dusk 17-20, night 20-05. The boundaries follow the
    /// sky, not the market: the widget lives on the desktop all day, and its
    /// light should agree with the window next to it.
    static func byHour(_ date: Date, calendar: Calendar = .current) -> BackdropImage {
        switch calendar.component(.hour, from: date) {
        case 5..<7: .dawn
        case 7..<8: .sunrise
        case 8..<13: .day
        case 13..<17: .noon
        case 17..<19: .dusk
        case 19..<20: .evening
        case 20..<24, 0..<1: .night
        default: .midnight
        }
    }

    /// A steady walk through the set, one step every three hours, anchored to
    /// the calendar so every launch on the same afternoon shows the same image --
    /// rotation should feel like a slow clock, not a slot machine.
    static func byRotation(_ date: Date, calendar: Calendar = .current) -> BackdropImage {
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let hour = calendar.component(.hour, from: date)
        let slot = (dayOfYear * 8 + hour / 3) % BackdropImage.allCases.count
        return BackdropImage.allCases[slot]
    }
}
