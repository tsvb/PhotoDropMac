import XCTest
@testable import PhotoDropMac

/// Integration tests for re-verification. Drive the public `Verifier` against
/// temp libraries with hand-written manifests.
///
/// The headline case is multi-manifest disagreement — and the rule is **report,
/// never reconcile**. This header used to describe verifying against "its newest
/// recorded hash", which was replaced precisely because every ordering signal is
/// attacker-chosen; see `VerifyEngine.build`. Agreement dedupes quietly,
/// disagreement is a `.conflict`.
@MainActor
final class VerifierTests: XCTestCase {

    // MARK: - Helpers

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacVerifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Writes `content` at `root/<relPath>` and returns its real xxHash64 (hex).
    @discardableResult
    private func writeFile(_ relPath: String, content: String, in root: URL) throws -> String {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return String(format: "%016llx", try XxHash64.hash(fileAt: url))
    }

    /// Writes a manifest into `root/PhotoDrop Manifests/ingest-<stamp>.json`.
    private func writeManifest(into root: URL, stamp: Date, createdAt: Date,
                               _ entries: [ManifestEntry]) throws {
        let manifest = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName, createdAt: createdAt,
            source: nil, primaryDestination: root.path(percentEncoded: false),
            archiveDestination: nil, destinations: nil, verified: true, partial: false,
            filesCopied: entries.count, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: entries)
        XCTAssertNotNil(ManifestWriter.write(manifest, intoRoot: root, stamp: stamp),
                        "manifest should write")
    }

    private func entry(_ path: String, hash: String?, status: String = "verified") -> ManifestEntry {
        ManifestEntry(name: (path as NSString).lastPathComponent, path: path,
                      bytes: 0, xxhash64: hash, status: status)
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    private func runVerifier(target: URL) async throws -> VerifyReport {
        let verifier = Verifier()
        verifier.start(target: target)
        var ticks = 0
        while verifier.isRunning && ticks < 200 {   // up to ~5s; the workload is tiny
            try await Task.sleep(nanoseconds: 25_000_000)
            ticks += 1
        }
        guard case .completed(let report) = verifier.state else {
            XCTFail("verify did not complete; state = \(verifier.state)")
            throw VerifierTestFailure.didNotComplete
        }
        return report
    }

    // MARK: - Tests

    func testMatchingFileVerifies() async throws {
        let root = try freshTempDir()
        let hash = try writeFile("2026/photo.bin", content: "hello world", in: root)
        try writeManifest(into: root, stamp: date(2026, 5, 1), createdAt: date(2026, 5, 1),
                          [entry("2026/photo.bin", hash: hash)])

        let report = try await runVerifier(target: root)
        XCTAssertTrue(report.allGood)
        XCTAssertEqual(report.verified, 1)
    }

    func testChangedFileIsReported() async throws {
        let root = try freshTempDir()
        let realHash = try writeFile("2026/photo.bin", content: "hello world", in: root)
        let wrongHash = String(format: "%016llx", (UInt64(realHash, radix: 16) ?? 0) ^ 0xFFFF)
        try writeManifest(into: root, stamp: date(2026, 5, 1), createdAt: date(2026, 5, 1),
                          [entry("2026/photo.bin", hash: wrongHash)])

        let report = try await runVerifier(target: root)
        XCTAssertEqual(report.changed, 1)
        XCTAssertEqual(report.verified, 0)
    }

    func testMissingFileIsReported() async throws {
        let root = try freshTempDir()
        // Manifest references a file that was never written.
        try writeManifest(into: root, stamp: date(2026, 5, 1), createdAt: date(2026, 5, 1),
                          [entry("2026/gone.bin", hash: "0000000000000001")])

        let report = try await runVerifier(target: root)
        XCTAssertEqual(report.missing, 1)
    }

    /// Two manifests recording *different* hashes for one file is reported as a
    /// conflict, not silently resolved in favour of either.
    ///
    /// This replaces an earlier "newest manifest wins" rule. That rule made the
    /// expected digest a function of `createdAt`, a field inside an
    /// unauthenticated file sitting in a folder that anyone who can write to the
    /// library can add to — so dropping in one JSON dated 2099 relabelled a
    /// tampered file as verified without touching the genuine manifest. Since
    /// every available ordering signal (in-file `createdAt`, the `ingest-<stamp>`
    /// filename, the file's mtime) is equally attacker-chosen, there is no
    /// trustworthy way to arbitrate — so the disagreement itself is the finding.
    func testConflictingManifestHashesAreReported() async throws {
        let root = try freshTempDir()
        let realHash = try writeFile("2026/photo.bin", content: "current good bytes", in: root)
        let staleHash = String(format: "%016llx", (UInt64(realHash, radix: 16) ?? 0) ^ 0xABCD)

        try writeManifest(into: root, stamp: date(2026, 1, 1), createdAt: date(2026, 1, 1),
                          [entry("2026/photo.bin", hash: staleHash)])
        try writeManifest(into: root, stamp: date(2026, 6, 1), createdAt: date(2026, 6, 1),
                          [entry("2026/photo.bin", hash: realHash)])

        let report = try await runVerifier(target: root)
        XCTAssertEqual(report.manifestCount, 2, "both manifests should be read")
        XCTAssertEqual(report.total, 1, "the file is accounted for exactly once")
        XCTAssertFalse(report.allGood)
        XCTAssertEqual(report.conflicts, 1)
        XCTAssertEqual(report.verified, 0, "a file whose records disagree is not hashed at all")
    }

    /// The common case must stay quiet: a re-ingest re-records what it skipped,
    /// so the same path appearing in several manifests with the *same* digest is
    /// normal and dedupes silently.
    func testAgreeingManifestsDoNotConflict() async throws {
        let root = try freshTempDir()
        let hash = try writeFile("2026/photo.bin", content: "current good bytes", in: root)

        try writeManifest(into: root, stamp: date(2026, 1, 1), createdAt: date(2026, 1, 1),
                          [entry("2026/photo.bin", hash: hash)])
        try writeManifest(into: root, stamp: date(2026, 6, 1), createdAt: date(2026, 6, 1),
                          [entry("2026/photo.bin", hash: hash)])

        let report = try await runVerifier(target: root)
        XCTAssertTrue(report.allGood)
        XCTAssertEqual(report.conflicts, 0)
        XCTAssertEqual(report.total, 1)
        XCTAssertEqual(report.verified, 1)
    }
}

private enum VerifierTestFailure: Error { case didNotComplete }

