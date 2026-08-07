import XCTest
@testable import PhotoDropMac

/// Assembling the ordered archive-destination list from the primary archive plus
/// the newline-separated "additional locations" field.
///
/// The dedup cases are data-safety regressions, not tidiness: a folder listed
/// twice (or listed once *and* used as the primary) makes the second copy pass
/// collide with the first, `O_EXCL` refuses to overwrite, and the bundle is
/// counted failed — so a completely successful ingest reports every bundle
/// failed while the photos sit safely on disk. Measured before this fix:
/// archive == primary with 3 bundles → 3 files landed, `filesFailed == 3`.
final class ArchiveDestinationsTests: XCTestCase {
    // Roots are directory URLs (trailing "/"); compare the path without it.
    private func paths(_ urls: [URL]) -> [String] {
        urls.map { url in
            let p = url.path(percentEncoded: false)
            return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
        }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveDestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testArchiveOnly() {
        XCTAssertEqual(paths(ArchiveDestinations.list(primary: "/lib", archive: "/nas", extra: "")), ["/nas"])
    }

    func testArchivePlusExtrasInOrder() {
        let list = ArchiveDestinations.list(primary: "/lib", archive: "/nas", extra: "/offsite\n/cloud")
        XCTAssertEqual(paths(list), ["/nas", "/offsite", "/cloud"])
    }

    func testEmptyArchiveUsesOnlyExtras() {
        XCTAssertEqual(paths(ArchiveDestinations.list(primary: "/lib", archive: "", extra: "/a\n/b")), ["/a", "/b"])
    }

    func testIgnoresBlankLinesAndSurroundingWhitespace() {
        let list = ArchiveDestinations.list(primary: "/lib", archive: "  /nas  ", extra: "\n  /a  \n\n/b\n")
        XCTAssertEqual(paths(list), ["/nas", "/a", "/b"])
    }

    func testDropsDuplicatePaths() {
        let list = ArchiveDestinations.list(primary: "/lib", archive: "/nas", extra: "/nas\n/a\n/a")
        XCTAssertEqual(paths(list), ["/nas", "/a"])
    }

    func testEmptyEverythingIsNoArchives() {
        XCTAssertTrue(ArchiveDestinations.list(primary: "/lib", archive: "  ", extra: "\n\n").isEmpty)
    }

    // MARK: - Never write one folder twice

    func testArchiveEqualToPrimaryIsDropped() {
        let list = ArchiveDestinations.list(primary: "/lib", archive: "/lib", extra: "")
        XCTAssertTrue(list.isEmpty, "the primary must never appear again as a mirror")
    }

    func testExtraEqualToPrimaryIsDropped() {
        let list = ArchiveDestinations.list(primary: "/lib", archive: "/nas", extra: "/lib\n/offsite")
        XCTAssertEqual(paths(list), ["/nas", "/offsite"])
    }

    func testTrailingSlashSpellingOfPrimaryIsDropped() {
        let list = ArchiveDestinations.list(primary: "/Volumes/Photos", archive: "/Volumes/Photos/", extra: "")
        XCTAssertTrue(list.isEmpty, "'/x/' and '/x' are one folder to the filesystem")
    }

    func testTrailingSlashSpellingsCollapseAmongMirrors() {
        let list = ArchiveDestinations.list(primary: "/lib", archive: "/Volumes/Photos/", extra: "/Volumes/Photos")
        XCTAssertEqual(paths(list), ["/Volumes/Photos"])
    }

    func testDotDotSpellingOfPrimaryIsDropped() {
        let list = ArchiveDestinations.list(primary: "/Volumes/Photos", archive: "/Volumes/Other/../Photos", extra: "")
        XCTAssertTrue(list.isEmpty)
    }

    /// The case a string comparison can't catch: two different paths that the
    /// filesystem resolves to one directory.
    func testSymlinkToPrimaryIsDropped() throws {
        let tmp = try tempDir()
        let real = tmp.appendingPathComponent("library", isDirectory: true)
        let link = tmp.appendingPathComponent("library-link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let list = ArchiveDestinations.list(primary: real.path, archive: link.path, extra: "")
        XCTAssertTrue(list.isEmpty, "a symlink to the primary is the primary")
    }

    func testDistinctRealFoldersAreBothKept() throws {
        let tmp = try tempDir()
        let a = tmp.appendingPathComponent("a", isDirectory: true)
        let b = tmp.appendingPathComponent("b", isDirectory: true)
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        let list = ArchiveDestinations.list(primary: tmp.path, archive: a.path, extra: b.path)
        XCTAssertEqual(list.count, 2, "genuinely different folders must survive dedup")
    }

    // MARK: - The CLI's explicit --archive list gets the same protection

    func testMirrorsDedupesExplicitCandidatesAgainstPrimary() {
        let list = ArchiveDestinations.mirrors(primary: "/lib", candidates: ["/lib", "/nas", "/nas/", "/offsite"])
        XCTAssertEqual(paths(list), ["/nas", "/offsite"])
    }

    func testMirrorsWithNoPrimaryStillDedupesAmongItself() {
        let list = ArchiveDestinations.mirrors(primary: "", candidates: ["/nas", "/nas"])
        XCTAssertEqual(paths(list), ["/nas"])
    }
}
