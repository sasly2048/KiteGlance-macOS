import Foundation
import SwiftUI
import KiteGlanceCore

struct WidgetState: Codable {
    var position: CGPoint = .zero
    var isExpanded: Bool = false
    var activeTab: String = "stocks"
    var pinMode: PinMode = .desktop
    var backdropMode: BackdropMode = .timeOfDay
    var customBackdropPath: String?
    var lastSync: Date?
    // `windowLevel` removed: it was persisted but never read. `pinMode` is what
    // actually drives the window level.

    private static let fileName = "widget-state.json"

    static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("KiteGlance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> WidgetState {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(WidgetState.self, from: data) else {
            return WidgetState()
        }
        return state
    }

    func save() {
        let url = WidgetState.fileURL
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension CGPoint: @retroactive Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(CGFloat.self, forKey: .x)
        let y = try container.decode(CGFloat.self, forKey: .y)
        self.init(x: x, y: y)
    }

    private enum CodingKeys: String, CodingKey {
        case x, y
    }
}