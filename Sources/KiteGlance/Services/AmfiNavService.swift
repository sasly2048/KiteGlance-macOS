import Foundation
import os.log

actor AmfiNavService {
    private let url = URL(string: "https://www.amfiindia.com/spages/NAVAll.txt")!
    private let logger = Logger(subsystem: "com.kiteglance", category: "AmfiNavService")

    private var cache: [String: Decimal]?
    private var cachedOn: Date?
    private var hasLiveNavs = false

    private static let cacheFileName = "amfi-nav.txt"

    private static var cacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("KiteGlance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(cacheFileName)
    }

    func getNav(for isin: String) async -> Decimal? {
        guard let table = await ensureCache() else { return nil }
        return table[isin.trimmingCharacters(in: .whitespaces)]
    }

    func getAllNavs() async -> [String: Decimal]? {
        return await ensureCache()
    }

    var hasLiveData: Bool { hasLiveNavs }

    private func ensureCache() async -> [String: Decimal]? {
        if let cache, let cachedOn, isSameISTDay(cachedOn, Date()) {
            return cache
        }

        // Try disk cache first
        if let (diskText, diskTime) = readDiskCache(),
           isSameISTDay(diskTime, Date()),
           let parsed = parseNavs(diskText) {
            self.cache = parsed
            self.cachedOn = diskTime
            self.hasLiveNavs = true
            return parsed
        }

        // Fetch from network
        do {
            var request = URLRequest(url: url)
            request.setValue("KiteGlance/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeRawData) }

            let parsed = parseNavs(text)
            self.cache = parsed
            self.cachedOn = Date()
            self.hasLiveNavs = true
            writeDiskCache(text)
            return parsed
        } catch {
            logger.warning("AMFI fetch failed: \(error.localizedDescription)")

            if cache == nil, let (diskText, diskTime) = readDiskCache(),
               let parsed = parseNavs(diskText) {
                self.cache = parsed
                self.cachedOn = diskTime
                self.hasLiveNavs = true
                logger.info("Using disk cache from \(diskTime.formatted())")
            }
            return cache
        }
    }

    private func readDiskCache() -> (String, Date)? {
        let url = Self.cacheURL
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return (text, modDate)
    }

    private func writeDiskCache(_ text: String) {
        let url = Self.cacheURL
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func parseNavs(_ text: String) -> [String: Decimal] {
        var map: [String: Decimal] = [:]
        map.reserveCapacity(20_000)

        text.enumerateLines { line, _ in
            guard line.count >= 20, line.contains(";"),
                  !line.hasPrefix("Scheme Code") else { return }

            let parts = line.split(separator: ";", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count >= 5 else { return }

            let navText = parts[4].trimmingCharacters(in: .whitespaces)
            guard let nav = Decimal(string: navText), nav > 0 else { return }

            let isinGrowth = parts[1].trimmingCharacters(in: .whitespaces)
            let isinReinvest = parts[2].trimmingCharacters(in: .whitespaces)

            if isinGrowth.count == 12 { map[isinGrowth] = nav }
            if isinReinvest.count == 12 { map[isinReinvest] = nav }
        }

        return map
    }

    private func isSameISTDay(_ a: Date, _ b: Date) -> Bool {
        let ist = TimeZone(identifier: "Asia/Kolkata")!
        let calA = Calendar.current.dateComponents(in: ist, from: a)
        let calB = Calendar.current.dateComponents(in: ist, from: b)
        return calA.year == calB.year && calA.month == calB.month && calA.day == calB.day
    }
}