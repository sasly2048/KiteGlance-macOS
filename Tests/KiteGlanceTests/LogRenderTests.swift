import XCTest
import KiteGlanceCore

/// Mirrors the Windows `LogTests.Render_*` cases. The renderer is the
/// part of `Log` that can actually be unit-tested without going through
/// `os.log` or the file sink.
final class LogRenderTests: XCTestCase {

    /// The default case: every named hole is replaced with its
    /// corresponding value. The order of substitution does not matter
    /// because `{Name}` syntax disambiguates.
    func testRendersAllHoles() {
        let rendered = Log.render(
            template: "Hello {Name}, your account is {Id}",
            properties: ["Name": "Avery", "Id": "AB1234"]
        )
        XCTAssertEqual(rendered, "Hello Avery, your account is AB1234")
    }

    /// A property not referenced in the template is ignored: the
    /// renderer is forward-compatible with the JSONL sink, which keeps
    /// the full property map even when the rendered text only uses
    /// some of it.
    func testUnknownHoleLeftAsLiteral() {
        let rendered = Log.render(
            template: "Hello {Name}",
            properties: ["Other": "ignored"]
        )
        // The whole point of "left as literal" is that the user can
        // see something is wrong. Stripping the hole would hide the
        // missing property.
        XCTAssertEqual(rendered, "Hello {Name}")
    }

    /// A property whose value is empty produces an empty replacement,
    /// not a missing hole. The two cases (missing property, present
    /// but empty value) are deliberately distinguishable in the log
    /// line: `Hello ` (empty) vs `Hello {Name}` (missing).
    func testEmptyValueProducesEmptyReplacement() {
        let rendered = Log.render(
            template: "Hello {Name}",
            properties: ["Name": ""]
        )
        XCTAssertEqual(rendered, "Hello ")
    }

    /// Holes with hyphens or underscores are still valid identifiers
    /// here -- the renderer does not validate the property name, only
    /// the surrounding `{` `}` characters. That is intentional: the
    /// schema is "any string surrounded by braces", and a stricter
    /// parser would reject property names the JSONL sink is happy to
    /// store.
    func testHyphenatedHoleIsReplaced() {
        let rendered = Log.render(
            template: "Account: {account-id}",
            properties: ["account-id": "AB1234"]
        )
        XCTAssertEqual(rendered, "Account: AB1234")
    }

    /// The same hole appearing twice is replaced in both places.
    func testRepeatedHoleIsReplacedTwice() {
        let rendered = Log.render(
            template: "{Name} said hi to {Name}",
            properties: ["Name": "Avery"]
        )
        XCTAssertEqual(rendered, "Avery said hi to Avery")
    }

    /// A template with no holes at all round-trips unchanged. This
    /// matters because the structured path is the only caller of
    /// `render` -- if it took a fixed-template branch, the renderer
    /// would have been dead code.
    func testTemplateWithoutHolesRoundTrips() {
        let rendered = Log.render(
            template: "Just a plain message",
            properties: ["Noise": "ignored"]
        )
        XCTAssertEqual(rendered, "Just a plain message")
    }
}