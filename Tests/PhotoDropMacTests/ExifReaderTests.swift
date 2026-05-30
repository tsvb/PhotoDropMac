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
}
