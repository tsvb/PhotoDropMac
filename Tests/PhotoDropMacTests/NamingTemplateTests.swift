import XCTest
@testable import PhotoDropMac

/// Pure-transform tests for the naming-template renderer and the path
/// sanitizer. Dates are built with `Calendar.current` and rendered with
/// `.current` (matching the renderer), at noon, so assertions are independent
/// of the test machine's time zone and free of midnight/DST boundary effects.
final class NamingTemplateTests: XCTestCase {
    private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return Calendar.current.date(from: c)!
    }

    private func ctx(description: String = "", cardLabel: String = "",
                     name: String = "IMG_0001.RAF", stem: String = "IMG_0001",
                     date: Date? = nil) -> TemplateContext {
        TemplateContext(date: date ?? localDate(2023, 11, 14),
                        description: description, originalName: name,
                        originalStem: stem, cardLabel: cardLabel)
    }

    // MARK: - Date tokens

    func testDateTokensRender() {
        XCTAssertEqual(TemplateRenderer.render("{yyyy-MM-dd}", ctx()), "2023-11-14")
        XCTAssertEqual(
            TemplateRenderer.render("{yyyyMMdd_HHmmss}", ctx(date: localDate(2023, 11, 14, 19, 55, 10))),
            "20231114_195510"
        )
    }

    // MARK: - Optional groups

    func testOptionalGroupDropsOnEmptyNamedToken() {
        XCTAssertEqual(TemplateRenderer.render("{yyyy-MM-dd}[_{Description}]", ctx(description: "")),
                       "2023-11-14")
    }

    func testOptionalGroupKeptWhenNamedTokenPresent() {
        XCTAssertEqual(TemplateRenderer.render("{yyyy-MM-dd}[_{Description}]", ctx(description: "Iceland")),
                       "2023-11-14_Iceland")
    }

    func testDateTokenInsideOptionalGroupNeverDrops() {
        // A date token is never "empty", so an optional group containing only a
        // date token is always kept.
        XCTAssertEqual(TemplateRenderer.render("x[_{HHmmss}]", ctx(date: localDate(2023, 11, 14, 1, 2, 3))),
                       "x_010203")
    }

    // MARK: - Named tokens

    func testNamedTokensResolve() {
        XCTAssertEqual(TemplateRenderer.render("{OriginalStem}", ctx(stem: "DSCF1839")), "DSCF1839")
        XCTAssertEqual(TemplateRenderer.render("{OriginalName}", ctx(name: "DSCF1839.RAF")), "DSCF1839.RAF")
        XCTAssertEqual(TemplateRenderer.render("{CardLabel}", ctx(cardLabel: "LEICA")), "LEICA")
    }

    // MARK: - Sanitizer

    func testSanitizeStripsPathSeparators() {
        XCTAssertEqual(PathPlanner.sanitize("a/b"), "a-b")
        XCTAssertEqual(PathPlanner.sanitize("a:b\\c"), "a-b-c")
    }

    func testSanitizeCollapsesSpacesAndTrims() {
        XCTAssertEqual(PathPlanner.sanitize("  hello world  "), "hello_world")
    }

    func testSanitizeWhitespaceOnlyBecomesEmpty() {
        XCTAssertEqual(PathPlanner.sanitize("   "), "")
    }

    // MARK: - Length cap (§3.2)

    func testSanitizeLeavesShortComponentUntouched() {
        XCTAssertEqual(PathPlanner.sanitize(String(repeating: "a", count: 255)).utf8.count, 255)
    }

    func testSanitizeTruncatesOverlongComponentToByteLimit() {
        let out = PathPlanner.sanitize(String(repeating: "a", count: 400))
        XCTAssertEqual(out.utf8.count, PathPlanner.maxComponentBytes)
        XCTAssertEqual(out, String(repeating: "a", count: 255))
    }

    func testSanitizeNeverSplitsMultibyteCharacters() {
        // "😀" is one grapheme = 4 UTF-8 bytes. 255 / 4 = 63 whole emoji (252 B);
        // a 64th would be 256 B > 255, so it's dropped — never split mid-character.
        let out = PathPlanner.sanitize(String(repeating: "😀", count: 200))
        XCTAssertLessThanOrEqual(out.utf8.count, PathPlanner.maxComponentBytes)
        XCTAssertEqual(out.count, 63)
        XCTAssertEqual(out.utf8.count, 252)
    }

    // MARK: - Traversal / hidden components (§3.1)

    func testSanitizeNeutralizesDotComponents() {
        XCTAssertEqual(PathPlanner.sanitize("."), "")
        XCTAssertEqual(PathPlanner.sanitize(".."), "")
        // "/" -> "-" gives "..-..-etc", then leading dots are stripped. The
        // result is a single safe component; no separators survive to traverse.
        XCTAssertEqual(PathPlanner.sanitize("../../etc"), "-..-etc")
    }

    func testSanitizeStripsLeadingDotsFromHiddenNames() {
        XCTAssertEqual(PathPlanner.sanitize(".hidden"), "hidden")
        XCTAssertEqual(PathPlanner.sanitize("...intro"), "intro")
    }

    func testSanitizeKeepsInteriorDots() {
        XCTAssertEqual(PathPlanner.sanitize("v1.2.3"), "v1.2.3")
    }

    // MARK: - Nested folder components

    func testSanitizedComponentsSplitsOnSlash() {
        XCTAssertEqual(PathPlanner.sanitizedComponents("05/2026-05-28"), ["05", "2026-05-28"])
        XCTAssertEqual(PathPlanner.sanitizedComponents("2026-05-28"), ["2026-05-28"])
    }

    func testSanitizedComponentsDropsEmptyAndTraversalSegments() {
        XCTAssertEqual(PathPlanner.sanitizedComponents("a//b"), ["a", "b"])
        XCTAssertEqual(PathPlanner.sanitizedComponents("../x"), ["x"])   // ".." -> "" -> dropped
        XCTAssertEqual(PathPlanner.sanitizedComponents(""), [])
        XCTAssertEqual(PathPlanner.sanitizedComponents("  /  "), [])
    }
}
