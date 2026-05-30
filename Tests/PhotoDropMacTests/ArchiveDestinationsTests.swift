import XCTest
@testable import PhotoDropMac

/// Assembling the ordered archive-destination list from the primary archive plus
/// the newline-separated "additional locations" field.
final class ArchiveDestinationsTests: XCTestCase {
    // Roots are directory URLs (trailing "/"); compare the path without it.
    private func paths(_ urls: [URL]) -> [String] {
        urls.map { url in
            let p = url.path(percentEncoded: false)
            return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
        }
    }

    func testArchiveOnly() {
        XCTAssertEqual(paths(ArchiveDestinations.list(archive: "/nas", extra: "")), ["/nas"])
    }

    func testArchivePlusExtrasInOrder() {
        let list = ArchiveDestinations.list(archive: "/nas", extra: "/offsite\n/cloud")
        XCTAssertEqual(paths(list), ["/nas", "/offsite", "/cloud"])
    }

    func testEmptyArchiveUsesOnlyExtras() {
        XCTAssertEqual(paths(ArchiveDestinations.list(archive: "", extra: "/a\n/b")), ["/a", "/b"])
    }

    func testIgnoresBlankLinesAndSurroundingWhitespace() {
        let list = ArchiveDestinations.list(archive: "  /nas  ", extra: "\n  /a  \n\n/b\n")
        XCTAssertEqual(paths(list), ["/nas", "/a", "/b"])
    }

    func testDropsDuplicatePaths() {
        let list = ArchiveDestinations.list(archive: "/nas", extra: "/nas\n/a\n/a")
        XCTAssertEqual(paths(list), ["/nas", "/a"])
    }

    func testEmptyEverythingIsNoArchives() {
        XCTAssertTrue(ArchiveDestinations.list(archive: "  ", extra: "\n\n").isEmpty)
    }
}
