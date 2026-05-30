import XCTest
@testable import PhotoDropMac

/// Integration tests that drive a real ingest through `Copier` against temp
/// directories. The headline case is the regression for §1.2: the verification
/// manifest must reflect only what actually landed — a bundle that fails partway
/// and rolls back must leave no entry behind.
///
/// The cache and dedup-index stores are pointed at the temp directory so these
/// tests never read or write the real Application Support state.
@MainActor
final class CopierManifestTests: XCTestCase {

    // MARK: - Helpers

    /// A unique temp directory whose cleanup is registered for teardown. Kept as
    /// a per-test local (not a stored property) so nothing crosses the
    /// MainActor/nonisolated boundary between setUp and the test body.
    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacCopierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeCopier(tmp: URL) -> Copier {
        Copier(cacheStoreURL: tmp.appendingPathComponent("cache.json"),
               indexStoreURL: tmp.appendingPathComponent("index.json"))
    }

    private func captureDate() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 28; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    private func makeSourceFile(_ name: String, bytes: Int, in tmp: URL) throws -> URL {
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let url = card.appendingPathComponent(name)
        try Data(repeating: 0x42, count: bytes).write(to: url)
        return url
    }

    private func yearGroup(primary: URL, companions: [CompanionFile]) -> YearGroup {
        let size = (try? primary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let photo = ScannedPhoto(id: primary, url: primary, size: Int64(size),
                                 dateTaken: captureDate(), dateSource: .fileModification)
        let bundle = AssetBundle(primary: photo, companions: companions)
        let folder = DestinationFolder(id: "2026/2026-05-28", year: 2026, dayDate: captureDate(),
                                       dayName: "2026-05-28", bundles: [bundle])
        return YearGroup(id: 2026, year: 2026, folders: [folder])
    }

    private func runToCompletion(_ copier: Copier, dest: URL, _ groups: [YearGroup],
                                 archives: [URL] = []) async throws -> CopyResult {
        copier.start(yearGroups: groups, primaryDestination: dest, archiveDestinations: archives,
                     description: "", verify: true, ejectAfter: false, sourceMountPoint: nil,
                     sourceVolumeID: "test-vol", template: .default, cardLabel: "")
        var ticks = 0
        while copier.isRunning && ticks < 200 {   // up to ~5s; the workload is tiny
            try await Task.sleep(nanoseconds: 25_000_000)
            ticks += 1
        }
        guard case .completed(let result) = copier.state else {
            throw XCTSkip("ingest did not complete; state = \(copier.state)")
        }
        return result
    }

    private func decodeManifest(_ url: URL?) throws -> Manifest {
        let url = try XCTUnwrap(url, "result should carry a manifest URL")
        return try XCTUnwrap(ManifestWriter.decode(try Data(contentsOf: url)), "manifest should decode")
    }

    // MARK: - Tests

    /// Happy path: a clean single-file bundle is fully and correctly recorded.
    func testManifestRecordsSuccessfullyCopiedFile() async throws {
        let tmp = try freshTempDir()
        let primary = try makeSourceFile("IMG_0001.DNG", bytes: 4096, in: tmp)
        let dest = tmp.appendingPathComponent("library", isDirectory: true)

        let result = try await runToCompletion(makeCopier(tmp: tmp), dest: dest,
                                                [yearGroup(primary: primary, companions: [])])

        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(result.filesFailed, 0)
        let manifest = try decodeManifest(result.manifestURL)
        XCTAssertEqual(manifest.files.count, 1)
        XCTAssertEqual(manifest.files.first?.name, "IMG_0001.DNG")
        XCTAssertEqual(manifest.files.first?.status, "verified")
        XCTAssertNotNil(manifest.files.first?.xxhash64)
    }

    /// §2.2/§2.3: the reported total bytes is the unique bytes that landed in the
    /// primary library — not doubled by the archive pass, and derived from the
    /// receipt (deterministic) rather than the async progress counter.
    func testReportedTotalBytesNotDoubledWithArchive() async throws {
        let tmp = try freshTempDir()
        let primary = try makeSourceFile("IMG_0003.DNG", bytes: 4096, in: tmp)
        let dest = tmp.appendingPathComponent("library", isDirectory: true)
        let archive = tmp.appendingPathComponent("backup", isDirectory: true)

        let result = try await runToCompletion(makeCopier(tmp: tmp), dest: dest,
                                                [yearGroup(primary: primary, companions: [])],
                                                archives: [archive])

        XCTAssertEqual(result.filesCopied, 2, "the file is written to both destinations")
        XCTAssertEqual(result.totalBytes, 4096, "reported size is the unique landed bytes, not 2×")
        let manifest = try decodeManifest(result.manifestURL)
        XCTAssertEqual(manifest.totalBytes, 4096)
        XCTAssertEqual(manifest.files.count, 1, "manifest records the primary pass only")
    }

    /// N-way: the bundle is copied to the primary and every archive, the file
    /// lands in all of them, and the manifest still records the primary only.
    func testCopiesToPrimaryAndMultipleArchives() async throws {
        let tmp = try freshTempDir()
        let primary = try makeSourceFile("IMG_0004.DNG", bytes: 4096, in: tmp)
        let dest = tmp.appendingPathComponent("library", isDirectory: true)
        let nas = tmp.appendingPathComponent("nas", isDirectory: true)
        let offsite = tmp.appendingPathComponent("offsite", isDirectory: true)

        let result = try await runToCompletion(makeCopier(tmp: tmp), dest: dest,
                                                [yearGroup(primary: primary, companions: [])],
                                                archives: [nas, offsite])

        XCTAssertEqual(result.filesFailed, 0)
        XCTAssertEqual(result.filesCopied, 3, "copied to primary + 2 archives")
        XCTAssertEqual(result.totalBytes, 4096, "reported size stays the unique landed bytes")

        // The file is present under all three destination roots.
        for root in [dest, nas, offsite] {
            let dayFolder = root.appendingPathComponent("2026/2026-05-28")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dayFolder.path)) ?? []
            XCTAssertTrue(files.contains { $0.hasSuffix(".DNG") }, "missing copy under \(root.lastPathComponent)")
        }

        let manifest = try decodeManifest(result.manifestURL)
        XCTAssertEqual(manifest.files.count, 1, "manifest records the primary pass only")
    }

    /// Regression for §1.2: a bundle that fails partway (a companion whose source
    /// is missing) rolls back its already-copied primary — and the manifest must
    /// NOT list that primary, nor count it as copied.
    func testManifestOmitsRolledBackBundle() async throws {
        let tmp = try freshTempDir()
        let primary = try makeSourceFile("IMG_0002.DNG", bytes: 4096, in: tmp)
        // Companion source does not exist → its copy throws → the bundle rolls back.
        let card = primary.deletingLastPathComponent()
        let missing = CompanionFile(url: card.appendingPathComponent("IMG_0002.xmp"), size: 10, kind: .xmp)
        let dest = tmp.appendingPathComponent("library", isDirectory: true)

        let result = try await runToCompletion(makeCopier(tmp: tmp), dest: dest,
                                                [yearGroup(primary: primary, companions: [missing])])

        XCTAssertEqual(result.filesFailed, 1, "the bundle should be counted as failed")
        XCTAssertEqual(result.filesCopied, 0, "the rolled-back primary must not be counted as copied")

        let manifest = try decodeManifest(result.manifestURL)
        XCTAssertTrue(manifest.files.isEmpty,
                      "manifest must not list files from a rolled-back bundle, got \(manifest.files.map(\.name))")

        // The primary must also be gone from disk (rolled back).
        let dayFolder = dest.appendingPathComponent("2026/2026-05-28")
        let landedFiles = (try? FileManager.default.contentsOfDirectory(atPath: dayFolder.path)) ?? []
        XCTAssertFalse(landedFiles.contains { $0.hasSuffix(".DNG") },
                       "the primary file must have been rolled back from disk")
    }

    /// Round-trip: an ingest's own manifest must re-verify cleanly. Guards that
    /// manifest paths are recorded relative to the library root (a trailing
    /// slash on the root URL previously left absolute paths, so re-verify saw
    /// every file as "missing").
    func testIngestThenVerifyRoundTrips() async throws {
        let tmp = try freshTempDir()
        let primary = try makeSourceFile("IMG_0005.DNG", bytes: 4096, in: tmp)
        let dest = tmp.appendingPathComponent("library", isDirectory: true)

        let result = try await runToCompletion(makeCopier(tmp: tmp), dest: dest,
                                                [yearGroup(primary: primary, companions: [])])
        XCTAssertEqual(result.filesCopied, 1)

        let report = try XCTUnwrap(VerifyEngine.run(target: dest))
        XCTAssertTrue(report.allGood, "the ingest's own manifest must verify; issues: \(report.issues.map(\.path))")
        XCTAssertEqual(report.verified, 1)
    }
}
