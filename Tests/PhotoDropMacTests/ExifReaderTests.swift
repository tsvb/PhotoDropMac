import XCTest
@testable import PhotoDropMac

/// `ExifReader.parse` — the pure parse of EXIF's zone-less "yyyy:MM:dd HH:mm:ss"
/// string, interpreted in the local zone. (The ImageIO `dateTaken(for:)` path
/// needs a real image fixture and isn't unit-tested here.)
final class ExifReaderTests: XCTestCase {
    private var localCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    func testParsesValidExifDateInLocalZone() throws {
        let date = try XCTUnwrap(ExifReader.parse("2026:05:30 12:34:56"))
        let c = localCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 5)
        XCTAssertEqual(c.day, 30)
        XCTAssertEqual(c.hour, 12)
        XCTAssertEqual(c.minute, 34)
        XCTAssertEqual(c.second, 56)
    }

    func testRejectsGarbage() {
        XCTAssertNil(ExifReader.parse("not a date"))
        XCTAssertNil(ExifReader.parse("2026-05-30T12:34:56Z"))   // wrong format
    }

    func testRejectsAllZeroDate() {
        // Cameras with an unset clock emit this; it must fail so the caller falls
        // back to the file's modification date rather than filing under year 0.
        XCTAssertNil(ExifReader.parse("0000:00:00 00:00:00"))
    }

    func testRejectsEmptyString() {
        XCTAssertNil(ExifReader.parse(""))
    }

    // MARK: - Movie timestamps follow the same wall-clock rule as stills

    private let newYork = TimeZone(identifier: "America/New_York")!

    private func components(_ date: Date, in zone: TimeZone) -> DateComponents {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// The defect: a still and a clip from the same Tokyo morning, ingested in
    /// New York, filed under two different day folders — the still by its
    /// wall clock, the clip by the instant rendered in the Mac's zone.
    func testAClipAndAStillFromTheSameMomentLandOnTheSameDay() throws {
        let still = try XCTUnwrap(ExifReader.parse("2026:05:29 08:00:00", timeZone: newYork))
        let clip = try XCTUnwrap(ExifReader.movieCaptureDate(from: "2026-05-29T08:00:00+0900", renderIn: newYork))
        XCTAssertEqual(components(still, in: newYork), components(clip, in: newYork))
        let c = components(clip, in: newYork)
        XCTAssertEqual([c.year, c.month, c.day, c.hour], [2026, 5, 29, 8],
                       "the camera's wall clock, not 19:00 the previous day")
    }

    func testOffsetShapesCamerasActuallyWrite() throws {
        for text in ["2026-05-29T08:00:00+0900",      // QuickTime creationdate, no colon
                     "2026-05-29T08:00:00+09:00",     // ISO with colon
                     "2026-05-29T08:00:00.500+0900",  // fractional seconds
                     "2026-05-29T08:00:00-0400",      // a western offset
                     "2026-05-29T08:00:00+00:00",     // an offset of zero is still a location
                     "2026-05-29 08:00:00+0900"] {    // a space for the T
            let date = try XCTUnwrap(ExifReader.movieCaptureDate(from: text, renderIn: newYork), text)
            let c = components(date, in: newYork)
            XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 5, 29, 8, 0, 0], text)
        }
    }

    /// `Z` is a camera that stores a true instant and does not know where it
    /// was. There is no wall clock to recover, so the instant is kept — exactly
    /// the previous behaviour, and the best available answer.
    func testZuluIsKeptAsAnInstant() throws {
        let date = try XCTUnwrap(ExifReader.movieCaptureDate(from: "2026-05-28T23:00:00Z", renderIn: newYork))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(date, formatter.date(from: "2026-05-28T23:00:00Z"))
        let c = components(date, in: newYork)
        XCTAssertEqual([c.day, c.hour], [28, 19])
    }

    /// No designator at all is EXIF's shape and gets EXIF's treatment.
    func testABareWallClockIsRebuiltLocally() throws {
        let date = try XCTUnwrap(ExifReader.movieCaptureDate(from: "2026-05-29T08:00:00", renderIn: newYork))
        let c = components(date, in: newYork)
        XCTAssertEqual([c.year, c.month, c.day, c.hour], [2026, 5, 29, 8])
    }

    func testMovieTimestampsThatAreNotDatesAreRejected() {
        XCTAssertNil(ExifReader.movieCaptureDate(from: "", renderIn: newYork))
        XCTAssertNil(ExifReader.movieCaptureDate(from: "yesterday", renderIn: newYork))
        XCTAssertNil(ExifReader.movieCaptureDate(from: "2026:05:29 08:00:00", renderIn: newYork), "EXIF's shape is not a movie timestamp")
        XCTAssertNil(ExifReader.movieCaptureDate(from: "2026-02-30T08:00:00+0900", renderIn: newYork), "a rolled-over date is rejected, as it is for stills")
        XCTAssertNil(ExifReader.movieCaptureDate(from: "0000-00-00T00:00:00Z", renderIn: newYork))
    }
}
