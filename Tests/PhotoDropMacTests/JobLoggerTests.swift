import XCTest
@testable import PhotoDropMac

/// The job log — the artifact a user reads afterwards to reconstruct what
/// happened to their photos. Previously untested entirely.
///
/// Every call here passes `directory:` so the suite never writes into the real
/// `~/Library/Logs/PhotoDrop`.
final class JobLoggerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private func entry(_ kind: LogEntry.Kind, _ line: String, signature: UInt64? = nil) -> LogEntry {
        LogEntry(timestamp: Date(timeIntervalSince1970: 1_780_000_000), kind: kind,
                 line: line, signature: signature)
    }

    @discardableResult
    private func writeLog(_ entries: [LogEntry], baseName: String? = nil) throws -> URL {
        let url = JobLogger.write(
            entries: entries,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            elapsedSeconds: 12.5,
            primaryDestination: URL(fileURLWithPath: "/lib"),
            archiveDestinations: [URL(fileURLWithPath: "/nas")],
            baseName: baseName,
            directory: dir)
        return try XCTUnwrap(url, "the log should have been written")
    }

    func testWritesALogContainingEveryEntry() throws {
        let url = try writeLog([
            entry(.info, "Starting ingest"),
            entry(.copied, "IMG_0001.CR2"),
            entry(.verified, "IMG_0001.CR2", signature: 0xDEADBEEFCAFEF00D),
            entry(.error, "something went wrong"),
        ])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Starting ingest"))
        XCTAssertTrue(text.contains("IMG_0001.CR2"))
        XCTAssertTrue(text.contains("something went wrong"))
        XCTAssertTrue(text.contains("deadbeefcafef00d"), "the verified digest is the point of the log")
    }

    func testRecordsBothDestinations() throws {
        let text = try String(contentsOf: try writeLog([entry(.info, "x")]), encoding: .utf8)
        XCTAssertTrue(text.contains("/lib"))
        XCTAssertTrue(text.contains("/nas"), "a mirror the job wrote to belongs in its record")
    }

    /// The log is named after the manifest's *resolved* stem so the pair can be
    /// found together even when the manifest took a collision suffix.
    func testUsesTheManifestBaseNameWhenGiven() throws {
        let url = try writeLog([entry(.info, "x")], baseName: "ingest-20260528-120000-000-2")
        XCTAssertEqual(url.lastPathComponent, "ingest-20260528-120000-000-2.log")
    }

    func testDerivesItsOwnStampWhenNoManifestWasWritten() throws {
        let url = try writeLog([entry(.info, "x")])
        XCTAssertTrue(url.lastPathComponent.hasPrefix("ingest-"))
        XCTAssertEqual(url.pathExtension, "log")
    }

    /// Same guarantee as the manifest: the name is *claimed* with O_EXCL, so a
    /// second job landing on the same stamp gets a suffix instead of silently
    /// destroying the first job's record.
    func testConcurrentJobsOnOneStampNeverOverwrite() throws {
        let first = try writeLog([entry(.info, "first job")], baseName: "ingest-collide")
        let second = try writeLog([entry(.info, "second job")], baseName: "ingest-collide")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8).contains("first job"), true,
                       "the first job's log must survive the second")
        XCTAssertTrue(try String(contentsOf: second, encoding: .utf8).contains("second job"))
    }

    func testUnwritableDirectoryReturnsNilRatherThanCrashing() throws {
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        try XCTSkipIf(getuid() == 0, "permissions do not constrain root")

        let url = JobLogger.write(entries: [entry(.info, "x")],
                                  startedAt: Date(), elapsedSeconds: 1,
                                  primaryDestination: URL(fileURLWithPath: "/lib"),
                                  archiveDestinations: [], directory: locked)
        XCTAssertNil(url, "logging is best-effort and must never fail the copy")
    }

    /// `defaultDirectory` is what production uses; assert it points where the
    /// docs say, since the injection point makes it easy to never exercise.
    func testDefaultDirectoryIsTheUserLogFolder() throws {
        let url = try XCTUnwrap(JobLogger.defaultDirectory)
        XCTAssertTrue(url.path.hasSuffix("/Library/Logs/PhotoDrop"), url.path)
    }
}
