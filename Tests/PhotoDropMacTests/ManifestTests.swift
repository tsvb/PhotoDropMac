import XCTest
@testable import PhotoDropMac

/// `Manifest` JSON round-trip, CSV serialization (RFC-4180 quoting), and
/// `ManifestWriter.manifestURLs` discovery — the receipt has to survive a
/// write/read cycle and quote fields safely.
final class ManifestTests: XCTestCase {

    private func manifest(_ entries: [ManifestEntry],
                          createdAt: Date = Date(timeIntervalSince1970: 1_716_000_000)) -> Manifest {
        Manifest(schema: Manifest.schemaID, app: Manifest.appName, createdAt: createdAt,
                 source: "SDCARD", primaryDestination: "/lib", archiveDestination: nil,
                 verified: true, filesCopied: entries.count, filesSkipped: 0, filesFailed: 0,
                 totalBytes: entries.reduce(0) { $0 + $1.bytes }, elapsedSeconds: 1.5, files: entries)
    }

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testJSONRoundTrip() throws {
        let m = manifest([
            ManifestEntry(name: "a.dng", path: "2026/2026-05-28/a.dng", bytes: 1234,
                          xxhash64: "00000000000000ff", status: "verified"),
            ManifestEntry(name: "b.xmp", path: "2026/2026-05-28/b.xmp", bytes: 10,
                          xxhash64: nil, status: "skipped"),
        ])
        let data = try XCTUnwrap(ManifestWriter.encodeJSON(m))
        let back = try XCTUnwrap(ManifestWriter.decode(data))

        XCTAssertEqual(back.schema, Manifest.schemaID)
        XCTAssertEqual(back.source, "SDCARD")
        XCTAssertEqual(back.totalBytes, 1244)
        XCTAssertEqual(back.createdAt.timeIntervalSince1970, m.createdAt.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(back.files.count, 2)
        XCTAssertEqual(back.files.first?.path, "2026/2026-05-28/a.dng")
        XCTAssertEqual(back.files.first?.xxhash64, "00000000000000ff")
        XCTAssertNil(back.files.last?.xxhash64)
        XCTAssertEqual(back.files.last?.status, "skipped")
    }

    func testCSVHeaderAndPlainRow() {
        let csv = ManifestWriter.csv(manifest([
            ManifestEntry(name: "a.dng", path: "2026/a.dng", bytes: 5, xxhash64: "abc", status: "copied"),
        ]))
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "name,path,bytes,xxhash64,status")
        XCTAssertEqual(lines[1], "a.dng,2026/a.dng,5,abc,copied")
    }

    func testCSVQuotesFieldsWithCommasAndQuotes() {
        let csv = ManifestWriter.csv(manifest([
            ManifestEntry(name: "a,b\"c.dng", path: "p/with,comma.dng", bytes: 1,
                          xxhash64: nil, status: "skipped"),
        ]))
        // A field containing a comma or quote is wrapped in quotes with internal
        // quotes doubled, per RFC 4180.
        XCTAssertTrue(csv.contains("\"a,b\"\"c.dng\""), "quote/comma field must be escaped: \(csv)")
        XCTAssertTrue(csv.contains("\"p/with,comma.dng\""))
    }

    func testManifestURLsFindsJSONForLibraryFolderAndDirectFile() throws {
        let root = try freshTempDir()
        let jsonURL = try XCTUnwrap(
            ManifestWriter.write(manifest([
                ManifestEntry(name: "a.dng", path: "2026/a.dng", bytes: 1, xxhash64: "00", status: "verified"),
            ]), intoRoot: root, stamp: Date(timeIntervalSince1970: 1_716_000_000)))

        // A library folder → finds the manifest inside its "PhotoDrop Manifests".
        XCTAssertEqual(ManifestWriter.manifestURLs(near: root).map(\.lastPathComponent),
                       [jsonURL.lastPathComponent])
        // A direct .json path → just that file.
        XCTAssertEqual(ManifestWriter.manifestURLs(near: jsonURL), [jsonURL])
    }
}
