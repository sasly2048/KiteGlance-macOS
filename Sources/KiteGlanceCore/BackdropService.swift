import Foundation

enum BackdropImage: String, CaseIterable {
    case dawn = "backdrop-dawn"
    case sunrise = "backdrop-sunrise"
    case day = "backdrop-day"
    case noon = "backdrop-noon"
    case dusk = "backdrop-dusk"
    case evening = "backdrop-evening"
    case night = "backdrop-night"
    case midnight = "backdrop-midnight"

    // `allCases` is synthesized by CaseIterable in declaration order, which is
    // already day order. Redeclaring it here conflicted with the synthesized
    // conformance.

    var displayName: String {
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

struct BackdropService {
    static func pick(mode: BackdropMode, date: Date = Date()) -> BackdropImage {
        switch mode {
        case .timeOfDay: return byHour(date)
        case .rotate: return byRotation(date)
        // Custom mode is not answered here -- the caller uses the user's file.
        case .static, .custom: return .day
        }
    }

    private static func byHour(_ date: Date) -> BackdropImage {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<7: return .dawn
        case 7..<8: return .sunrise
        case 8..<13: return .day
        case 13..<17: return .noon
        case 17..<19: return .dusk
        case 19..<20: return .evening
        case 20..<24, 0..<1: return .night
        default: return .midnight
        }
    }

    private static func byRotation(_ date: Date) -> BackdropImage {
        let cal = Calendar.current
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: date) ?? 1
        let hour = cal.component(.hour, from: date)
        let slot = (dayOfYear * 8 + hour / 3) % BackdropImage.allCases.count
        return BackdropImage.allCases[slot]
    }
}