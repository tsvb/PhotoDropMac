import XCTest
@testable import PhotoDropMac

/// Direct, synchronous tests of the extracted `VerifyEngine` — match / changed /
/// missing, newest-manifest-wins, the empty case, cancellation, and the
/// per-file progress callback. (The `Verifier` controller wrapper is covered
/// separately by `VerifierTests`.)
final class VerifyEngineTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacVerifyEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @discardableResult
    private func writeFile(_ relPath: String, content: String, in root: URL) throws -> String {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return String(format: "%016llx", try XxHash64.hash(fileAt: url))
    }

    private func entry(_ path: String, hash: String?) -> ManifestEntry {
        ManifestEntry(name: (path as NSString).lastPathComponent, path: path,
                      bytes: 0, xxhash64: hash, status: "verified")
    }

    private func writeManifest(into root: URL, stamp: Date, createdAt: Date, _ entries: [ManifestEntry]) throws {
        let manifest = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName, createdAt: createdAt,
            source: nil, primaryDestination: root.path(percentEncoded: false),
            archiveDestination: nil, destinations: nil, verified: true,
            filesCopied: entries.count, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: entries)
        XCTAssertNotNil(ManifestWriter.write(manifest, intoRoot: root, stamp: stamp))
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    func testMatchingFileVerifies() throws {
        let root = try freshTempDir()
        let hash = try writeFile("2026/photo.bin", content: "hello world", in: root)
        try writeManifest(into: root, stamp: date(2026, 5, 1), createdAt: date(2026, 5, 1),
                          [entry("2026/photo.bin", hash: hash)])
        let report = try XCTUnwrap(VerifyEngine.run(target: root))
        XCTAssertTrue(report.allGood)
        XCTAssertEqual(report.verified, 1)
    }

    func testChangedFileIsReported() throws {
        let root = try freshTempDir()
        let real = try writeFile("p.bin", content: "hello", in: root)
        let wrong = String(format: "%016llx", (UInt64(real, radix: 16) ?? 0) ^ 0xFFFF)
        try writeManifest(into: root, stamp: date(2026, 5, 1), createdAt: date(2026, 5, 1),
                          [entry("p.bin", hash: wrong)])
        let report = try XCTUnwrap(VerifyEngine.run(target: root))
        XCTAssertEqual(report.changed, 1)
        XCTAssertEqual(report.verified, 0)
    }

    func testMissingFileIsReported() throws {
        let root = try freshTempDir()
        try writeManifest(into: root, stamp: date(2026, 5, 1), createdAt: date(2026, 5, 1),
                          [entry("gone.bin", hash: "0000000000000001")])
        XCTAssertEqual(try XCTUnwrap(VerifyEngine.run(target: root)).missing, 1)
    }

    /// Replaces an earlier "newest manifest wins" rule: `createdAt` lives inside
    /// an unauthenticated file, so letting it pick the expected digest let a
    /// planted manifest launder a tampered file. Disagreement is now reported.
    /// See `VerifierTests.testConflictingManifestHashesAreReported`.
    func testManifestsDisagreeingOnAHashConflict() throws {
        let root = try freshTempDir()
        let real = try writeFile("p.bin", content: "current good", in: root)
        let stale = String(format: "%016llx", (UInt64(real, radix: 16) ?? 0) ^ 0xABCD)
        try writeManifest(into: root, stamp: date(2026, 1, 1), createdAt: date(2026, 1, 1),
                          [entry("p.bin", hash: stale)])
        try writeManifest(into: root, stamp: date(2026, 6, 1), createdAt: date(2026, 6, 1),
                          [entry("p.bin", hash: real)])
        let report = try XCTUnwrap(VerifyEngine.run(target: root))
        XCTAssertEqual(report.manifestCount, 2)
        XCTAssertEqual(report.total, 1)
        XCTAssertFalse(report.allGood)
        XCTAssertEqual(report.conflicts, 1)
    }

    func testManifestsAgreeingOnAHashDedupe() throws {
        let root = try freshTempDir()
        let real = try writeFile("p.bin", content: "current good", in: root)
        try writeManifest(into: root, stamp: date(2026, 1, 1), createdAt: date(2026, 1, 1),
                          [entry("p.bin", hash: real)])
        try writeManifest(into: root, stamp: date(2026, 6, 1), createdAt: date(2026, 6, 1),
                          [entry("p.bin", hash: real)])
        let report = try XCTUnwrap(VerifyEngine.run(target: root))
        XCTAssertEqual(report.total, 1)
        XCTAssertTrue(report.allGood)
    }

    func testEmptyWhenNoManifest() throws {
        let report = try XCTUnwrap(VerifyEngine.run(target: try freshTempDir()))
        XCTAssertEqual(report.total, 0)
        XCTAssertEqual(report.manifestCount, 0)
    }

    func testCancellationReturnsNil() throws {
        let root = try freshTempDir()
        let hash = try writeFile("a.bin", content: "x", in: root)
        try writeManifest(into: root, stamp: date(2026, 5, 1), createdAt: date(2026, 5, 1),
                          [entry("a.bin", hash: hash)])
        XCTAssertNil(VerifyEngine.run(target: root, isCancelled: { true }))
    }

    func testProgressCallbackFiresPerFile() throws {
        let root = try freshTempDir()
        let h1 = try writeFile("a.bin", content: "one", in: root)
        let h2 = try writeFile("b.bin", content: "two", in: root)
        try writeManifest(into: root, stamp: date(2026, 5, 1), createdAt: date(2026, 5, 1),
                          [entry("a.bin", hash: h1), entry("b.bin", hash: h2)])

        var ticks: [VerifyProgress] = []
        _ = VerifyEngine.run(target: root, onProgress: { ticks.append($0) })
        XCTAssertEqual(ticks.count, 2)
        XCTAssertEqual(ticks.last?.checked, 2)
        XCTAssertEqual(ticks.last?.total, 2)
    }
}
