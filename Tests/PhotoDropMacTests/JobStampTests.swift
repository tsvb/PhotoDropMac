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
}
