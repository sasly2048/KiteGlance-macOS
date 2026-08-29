import XCTest
@testable import KiteGlanceCore

/// Ported from tests/KiteGlance.Tests/BackdropServiceTests.cs.
final class BackdropServiceTests: XCTestCase {

    /// IST, not UTC. The widget draws the Indian sky; the test mirrors the
    /// production timezone so a date-constructed hour is what the runtime
    /// reads off the same clock. Earlier revisions used UTC so the hour
    /// boundaries under test were the ones being asserted, not the ones the
    /// build machine's time zone happened to produce -- but that masked the
    /// production bug where a non-IST system clock produced wrong backdrops.
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return cal
    }()

    private func date(hour: Int, day: Int = 15, month: Int = 6) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    func testHourBoundariesFollowTheSky() {
        let expectations: [(hour: Int, image: BackdropImage)] = [
            (5, .dawn), (6, .dawn),
            (7, .sunrise),
            (8, .day), (12, .day),
            (13, .noon), (16, .noon),
            (17, .dusk), (18, .dusk),
            (19, .evening),
            (20, .night), (23, .night), (0, .night),
            (1, .midnight), (4, .midnight)
        ]

        for (hour, expected) in expectations {
            let actual = BackdropService.byHour(date(hour: hour))
            XCTAssertEqual(actual, expected, "hour \(hour)")
        }
    }

    func testEveryHourResolvesToABackdrop() {
        for hour in 0..<24 {
            _ = BackdropService.byHour(date(hour: hour))
        }
    }

    func testStaticModeAlwaysReturnsTheGraphiteBackdrop() {
        XCTAssertEqual(BackdropService.pick(mode: .static, date: date(hour: 3)), .day)
    }

    /// Custom mode is not answered by the service -- the caller substitutes the
    /// user's own file -- so it returns the neutral default.
    func testCustomModeFallsBackToTheDefault() {
        XCTAssertEqual(BackdropService.pick(mode: .custom, date: date(hour: 3)), .day)
    }

    func testTimeOfDayModeDelegatesToTheClock() {
        XCTAssertEqual(BackdropService.pick(mode: .timeOfDay, date: date(hour: 21)), .night)
    }

    /// Rotation should feel like a slow clock: the same three-hour slot on the
    /// same day always yields the same image.
    func testRotationIsStableWithinAThreeHourSlot() {
        let first = BackdropService.byRotation(date(hour: 12))
        let second = BackdropService.byRotation(date(hour: 14))
        XCTAssertEqual(first, second)
    }

    func testRotationAdvancesToTheNextSlot() {
        let slot = BackdropService.byRotation(date(hour: 12))
        let next = BackdropService.byRotation(date(hour: 15))
        XCTAssertNotEqual(slot, next)
    }

    func testAllEightBackdropsAreReachableByRotation()  {
        var seen = Set<BackdropImage>()
        for day in 1...8 {
            for hour in stride(from: 0, to: 24, by: 3) {
                seen.insert(BackdropService.byRotation(date(hour: hour, day: day)))
            }
        }
        XCTAssertEqual(seen.count, BackdropImage.allCases.count)
    }

    func testEveryBackdropHasADisplayName() {
        for image in BackdropImage.allCases {
            XCTAssertFalse(image.displayName.isEmpty, "\(image) has no display name")
        }
    }
}
