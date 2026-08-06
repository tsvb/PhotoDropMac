import XCTest
@testable import PhotoDropMac

/// The stamp that names a job's manifest and log.
///
/// These are durability tests, not formatting preferences: `ManifestWriter`
/// writes `.atomic`, so two jobs sharing a stamp means the second silently
/// replaces the first's manifest — and the manifest is the only record of what
/// a job copied and at what digest.
final class JobStampTests: XCTestCase {
    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacStampTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func manifest(_ createdAt: Date, root: URL) -> Manifest {
        Manifest(schema: Manifest.schemaID, app: Manifest.appName, createdAt: createdAt,
                 source: nil, primaryDestination: root.path(percentEncoded: false),
                 archiveDestination: nil, destinations: nil, verified: true,
                 filesCopied: 1, filesSkipped: 0, filesFailed: 0,
                 totalBytes: 0, elapsedSeconds: 0, files: [])
    }

    /// The regression. Two ingests inside one second used to produce one
    /// manifest file, because the stamp only resolved to seconds.
    func testTwoJobsInTheSameSecondGetDistinctStamps() {
        let a = Date(timeIntervalSince1970: 1_716_000_000.100)
        let b = Date(timeIntervalSince1970: 1_716_000_000.900)
        XCTAssertNotEqual(JobStamp.fileStamp(a), JobStamp.fileStamp(b),
                          "same-second jobs must not share a filename")
    }

    func testTwoManifestsInTheSameSecondBothSurvive() throws {
        let root = try freshTempDir()
        let first = Date(timeIntervalSince1970: 1_716_000_000.100)
        let second = Date(timeIntervalSince1970: 1_716_000_000.900)

        XCTAssertNotNil(ManifestWriter.write(manifest(first, root: root), intoRoot: root, stamp: first))
        XCTAssertNotNil(ManifestWriter.write(manifest(second, root: root), intoRoot: root, stamp: second))

        let dir = root.appendingPathComponent(ManifestWriter.folderName, isDirectory: true)
        let jsons = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(jsons.count, 2, "the second write must not clobber the first")
    }

    /// Sortable-as-text ordering is what makes the folder listing chronological
    /// and gives `VerifyEngine` a stable tiebreaker.
    func testStampsSortChronologicallyAsStrings() {
        let stamps = [
            JobStamp.fileStamp(Date(timeIntervalSince1970: 1_716_000_000.100)),
            JobStamp.fileStamp(Date(timeIntervalSince1970: 1_716_000_000.900)),
            JobStamp.fileStamp(Date(timeIntervalSince1970: 1_716_000_001.000)),
            JobStamp.fileStamp(Date(timeIntervalSince1970: 1_716_000_060.000)),
        ]
        XCTAssertEqual(stamps, stamps.sorted(), "lexical order must match chronological order")
    }

    /// The stamp is embedded in a filename, so it must not contain a `.` (which
    /// would read as an extension) or any path separator.
    func testStampIsFilenameSafe() {
        let stamp = JobStamp.fileStamp(Date(timeIntervalSince1970: 1_716_000_000.123))
        XCTAssertFalse(stamp.contains("."))
        XCTAssertFalse(stamp.contains("/"))
        XCTAssertFalse(stamp.contains(":"))
        XCTAssertEqual(URL(fileURLWithPath: "/tmp/ingest-\(stamp).json").pathExtension, "json")
    }

    /// The manifest and the log are found by pairing their filenames, so both
    /// must render the same stamp for one job.
    func testManifestAndLogShareOneStamp() throws {
        let root = try freshTempDir()
        let started = Date(timeIntervalSince1970: 1_716_000_000.456)
        let url = try XCTUnwrap(ManifestWriter.write(manifest(started, root: root),
                                                     intoRoot: root, stamp: started))
        let manifestStem = url.deletingPathExtension().lastPathComponent
        XCTAssertEqual(manifestStem, "ingest-\(JobStamp.fileStamp(started))")
    }

    // MARK: - O_EXCL name claiming

    /// Precision reduces collisions; the claim is what makes overwriting
    /// impossible. Same stamp, twice, must yield two files.
    func testIdenticalStampsStillProduceTwoManifests() throws {
        let root = try freshTempDir()
        let same = Date(timeIntervalSince1970: 1_716_000_000.500)

        let first = try XCTUnwrap(ManifestWriter.write(manifest(same, root: root), intoRoot: root, stamp: same))
        let second = try XCTUnwrap(ManifestWriter.write(manifest(same, root: root), intoRoot: root, stamp: same))

        XCTAssertNotEqual(first, second, "an identical stamp must not reuse the name")
        let dir = root.appendingPathComponent(ManifestWriter.folderName, isDirectory: true)
        let jsons = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(jsons.count, 2)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-2.json"),
                      "the collision suffix should be visible: \(second.lastPathComponent)")
    }

    /// The CSV must follow the JSON's *resolved* base, or a collision would
    /// leave `ingest-X-2.json` paired with `ingest-X.csv`.
    func testCSVFollowsTheResolvedJSONName() throws {
        let root = try freshTempDir()
        let same = Date(timeIntervalSince1970: 1_716_000_000.500)
        _ = ManifestWriter.write(manifest(same, root: root), intoRoot: root, stamp: same)
        let second = try XCTUnwrap(ManifestWriter.write(manifest(same, root: root), intoRoot: root, stamp: same))

        let expectedCSV = second.deletingPathExtension().appendingPathExtension("csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedCSV.path),
                      "expected \(expectedCSV.lastPathComponent) beside its JSON")
    }

    /// The real scenario: separate processes racing for one name. Threads stand
    /// in for processes — O_EXCL is arbitrated by the kernel either way, so a
    /// lost claim would show up here as a duplicate URL or a missing file.
    func testConcurrentClaimsNeverCollide() throws {
        let dir = try freshTempDir()
        let count = 64
        let lock = NSLock()
        var claimed: [URL] = []

        DispatchQueue.concurrentPerform(iterations: count) { _ in
            if let url = JobStamp.claimUniqueName(in: dir, base: "ingest-20260806-093823-074",
                                                  pathExtension: "json") {
                lock.lock(); claimed.append(url); lock.unlock()
            }
        }

        XCTAssertEqual(claimed.count, count, "every racer should get a name")
        XCTAssertEqual(Set(claimed).count, count, "no two racers may be handed the same name")
        let onDisk = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(onDisk.count, count, "every claim must exist on disk")
    }

    func testClaimReturnsNilForAnUnwritableDirectory() {
        let missing = URL(fileURLWithPath: "/var/db/definitely-not-writable-\(UUID().uuidString)")
        XCTAssertNil(JobStamp.claimUniqueName(in: missing, base: "ingest-x", pathExtension: "json"))
    }
}
