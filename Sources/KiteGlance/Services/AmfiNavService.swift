import Foundation
import KiteGlanceCore
import os.log

actor AmfiNavService {
    private let url = URL(string: "https://www.amfiindia.com/spages/NAVAll.txt")!
    private let logger = Logger(subsystem: "com.kiteglance", category: "AmfiNavService")
    /// HTTP session. Injected so the test target can swap in a
    /// `URLProtocol`-mocked session; the production initialiser leaves
    /// it as `URLSession.shared`.
    private let session: URLSession

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

    convenience init() {
        self.init(session: .shared)
    }

    init(session: URLSession) {
        self.session = session
    }

    func getNav(for isin: String) async -> Decimal? {
        let trimmed = isin.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let table = await ensureCache() else { return nil }
        return table[trimmed]
    }

    func getAllNavs() async -> [String: Decimal]? {
        return await ensureCache()
    }

    var hasLiveData: Bool { hasLiveNavs }

    private func ensureCache() async -> [String: Decimal]? {
        if let cache, let cachedOn, isSameISTDay(cachedOn, Date()) {
            return cache
        }

        // Disk cache: survives restarts, so a cold start paints immediately from
        // a same-IST-day file instead of blocking on a ~3 MB download. Same-day
        // data is as authoritative as a fresh fetch -- AMFI publishes once, near
        // 11 PM IST -- so this path does count as live.
        if let (diskText, diskTime) = readDiskCache(), isSameISTDay(diskTime, Date()) {
            let parsed = parseNavs(diskText)
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

            let (data, _) = try await session.data(for: request)
            guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeRawData) }

            let parsed = parseNavs(text)
            self.cache = parsed
            self.cachedOn = Date()
            self.hasLiveNavs = true
            writeDiskCache(text)
            return parsed
        } catch {
            logger.warning("AMFI fetch failed: \(error.localizedDescription, privacy: .public)")
            await Log.shared.structured(
                .warn,
                "AMFI fetch failed ({Error}); falling back to disk cache",
                properties: ["Error": error.localizedDescription]
            )

            // Network failed. A day-old NAV still beats Kite's holdings-endpoint
            // NAV, so prefer a stale disk cache over nothing. But this data is
            // by definition not today's: `hasLiveNavs` stays false so the UI can
            // say "fund NAVs delayed" instead of quietly implying they are live.
            if cache == nil, let (diskText, diskTime) = readDiskCache() {
                let parsed = parseNavs(diskText)
                self.cache = parsed
                self.cachedOn = diskTime
                logger.info("Using stale disk cache from \(diskTime.formatted(), privacy: .public)")
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

    /// Delegates to the parser in KiteGlanceCore so the format is covered by
    /// tests rather than only exercised against the live feed.
    private func parseNavs(_ text: String) -> [String: Decimal] {
        NavParser.parse(text)
    }

    /// Explicitly Gregorian: `Calendar.current` follows the user's locale, and a
    /// non-Gregorian calendar (Buddhist, Japanese, Hijri -- all selectable in
    /// macOS System Settings) yields different year/month/day numbers for the
    /// same instant, silently breaking cache expiry.
    private func isSameISTDay(_ a: Date, _ b: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar.isDate(a, inSameDayAs: b)
    }
}