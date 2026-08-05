import AppKit
import SwiftUI

/// Resource loading for a SwiftPM executable.
///
/// `Image("backdrop-dawn")` only resolves names in an asset catalog, which this
/// target does not have -- SwiftPM copies loose files into `Bundle.module`
/// instead. Every backdrop reference therefore has to go through an explicit
/// bundle lookup. The previous code used the asset-catalog form and silently
/// rendered nothing.
enum Assets {
    private static var cache: [String: NSImage] = [:]

    static func backdrop(_ image: BackdropImage) -> NSImage? {
        load(named: image.rawValue)
    }

    static var grain: NSImage? {
        load(named: "grain")
    }

    /// Backdrops ship as PNGs. The repository currently carries `.txt`
    /// placeholders of the same name, which are deliberately not loadable --
    /// `NSImage` returns nil and the caller falls back to a gradient.
    private static func load(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }

        guard let url = Bundle.module.url(forResource: name, withExtension: "png")
                ?? Bundle.module.url(forResource: name, withExtension: "jpg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        cache[name] = image
        return image
    }
}

extension BackdropImage {
    /// A two-stop gradient standing in for the pre-rendered mesh gradient.
    /// Colours are sampled from the corresponding Windows asset so the widget
    /// reads the same at a glance even before real art is generated.
    var fallbackGradient: LinearGradient {
        LinearGradient(
            colors: gradientStops,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var gradientStops: [Color] {
        switch self {
        case .dawn:     [Color(hex: 0x2A2438), Color(hex: 0x5C4A6B)]
        case .sunrise:  [Color(hex: 0x3D2C3E), Color(hex: 0x8A5A4E)]
        case .day:      [Color(hex: 0x1E2A38), Color(hex: 0x3C5A73)]
        case .noon:     [Color(hex: 0x1B2C3B), Color(hex: 0x2F6382)]
        case .dusk:     [Color(hex: 0x2E2233), Color(hex: 0x7A4352)]
        case .evening:  [Color(hex: 0x231D2E), Color(hex: 0x4A3556)]
        case .night:    [Color(hex: 0x121620), Color(hex: 0x252F42)]
        case .midnight: [Color(hex: 0x0C0F16), Color(hex: 0x171D2A)]
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
