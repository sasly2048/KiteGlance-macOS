import XCTest
@testable import KiteGlanceCore

final class RefreshIntervalTests: XCTestCase {

    func testZeroMeansOff() {
        XCTAssertNil(RefreshInterval.effective(0))
    }

    func testDefaultIsUsedAsIs() {
        XCTAssertEqual(RefreshInterval.effective(RefreshInterval.default), 5)
    }

    /// The clamp is on read, so a value that reached the JSON some other way --
    /// an older build, a hand edit -- still cannot schedule a runaway timer.
    func testOutOfRangeValuesAreClampedOnRead() {
        XCTAssertEqual(RefreshInterval.effective(-30), RefreshInterval.minimum)
        XCTAssertEqual(RefreshInterval.effective(9999), RefreshInterval.maximum)
    }

    func testBoundsAreInclusive() {
        XCTAssertEqual(RefreshInterval.effective(1), 1)
        XCTAssertEqual(RefreshInterval.effective(60), 60)
    }

    /// Every offered choice must survive the clamp unchanged, or the picker
    /// would silently show a value the app does not use.
    func testEveryOfferedChoiceSurvivesTheClamp() {
        for choice in RefreshInterval.choices {
            XCTAssertEqual(RefreshInterval.effective(choice), choice)
        }
    }
}

final class ThemeModeTests: XCTestCase {

    func testExplicitModesOverrideTheSystem() {
        XCTAssertEqual(ResolvedTheme.resolve(mode: .dark, systemIsDark: false), .dark)
        XCTAssertEqual(ResolvedTheme.resolve(mode: .light, systemIsDark: true), .light)
    }

    func testSystemModeFollowsTheOS() {
        XCTAssertEqual(ResolvedTheme.resolve(mode: .system, systemIsDark: true), .dark)
        XCTAssertEqual(ResolvedTheme.resolve(mode: .system, systemIsDark: false), .light)
    }
}
