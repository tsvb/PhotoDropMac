import XCTest
@testable import PhotoDropMac

/// Storing/reading the per-file checksum extended attribute.
final class FileChecksumXattrTests: XCTestCase {
    private func tempFile(_ content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacXattrTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.bin")
        try Data(content.utf8).write(to: url)
        return url
    }

    func testStampAndReadRoundTrip() throws {
        let url = try tempFile("hello")
        XCTAssertNil(FileChecksumXattr.read(from: url), "an unstamped file has no checksum")
        XCTAssertTrue(FileChecksumXattr.stamp(0xDEAD_BEEF_1234_5678, on: url))
        XCTAssertEqual(FileChecksumXattr.read(from: url), 0xDEAD_BEEF_1234_5678)
    }

    func testRestampOverwrites() throws {
        let url = try tempFile("hi")
        FileChecksumXattr.stamp(0x1111_1111_1111_1111, on: url)
        FileChecksumXattr.stamp(0x2222_2222_2222_2222, on: url)
        XCTAssertEqual(FileChecksumXattr.read(from: url), 0x2222_2222_2222_2222)
    }
}

/// Manifest-free verification via the per-file checksum xattr.
final class VerifyEngineXattrTests: XCTestCase {
    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacXattrVerifyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @discardableResult
    private func writeStamped(_ relPath: String, content: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        FileChecksumXattr.stamp(try XxHash64.hash(fileAt: url), on: url)
        return url
    }

    /// Unwraps the `.report` case, failing the test on any other outcome.
    private func report(_ outcome: VerifyEngine.XattrOutcome,
                        file: StaticString = #filePath, line: UInt = #line) throws -> VerifyReport {
        guard case .report(let r) = outcome else {
            XCTFail("expected a report, got \(outcome)", file: file, line: line)
            throw XCTSkip("no report")
        }
        return r
    }

    func testVerifiesStampedFiles() throws {
        let root = try freshTempDir()
        try writeStamped("2026/a.bin", content: "one", in: root)
        try writeStamped("2026/b.bin", content: "two", in: root)
        let report = try report(VerifyEngine.runXattr(folder: root))
        XCTAssertTrue(report.allGood)
        XCTAssertEqual(report.verified, 2)
    }

    func testReportsChangedStampedFile() throws {
        let root = try freshTempDir()
        let a = try writeStamped("a.bin", content: "one", in: root)
        try Data("CHANGED".utf8).write(to: a)   // content edited; stamped digest now stale
        let report = try report(VerifyEngine.runXattr(folder: root))
        XCTAssertEqual(report.changed, 1)
        XCTAssertEqual(report.verified, 0)
    }

    func testIgnoresUnstampedFiles() throws {
        let root = try freshTempDir()
        try writeStamped("a.bin", content: "one", in: root)
        try Data("plain".utf8).write(to: root.appendingPathComponent("b.bin"))   // no xattr
        let report = try report(VerifyEngine.runXattr(folder: root))
        XCTAssertEqual(report.total, 1, "only the stamped file is checked")
        XCTAssertTrue(report.allGood)
    }

    func testEmptyWhenNothingStamped() throws {
        let root = try freshTempDir()
        try Data("plain".utf8).write(to: root.appendingPathComponent("b.bin"))
        XCTAssertEqual(try report(VerifyEngine.runXattr(folder: root)).total, 0)
    }

    // MARK: - An unreadable target is not "nothing stamped"

    /// Regression: both cases returned an empty report, so `photodrop verify
    /// --xattr` printed "No checksummed files found" and **exited 0** for a path
    /// it had never opened. A typo in a script got a permanent green check.
    func testMissingFolderIsAnUnreadableTarget() throws {
        let root = try freshTempDir()
        let outcome = VerifyEngine.runXattr(folder: root.appendingPathComponent("nope", isDirectory: true))
        guard case .unreadableTarget = outcome else {
            return XCTFail("a nonexistent folder must not report success, got \(outcome)")
        }
    }

    func testFileTargetIsAnUnreadableTarget() throws {
        let root = try freshTempDir()
        let file = root.appendingPathComponent("a.bin")
        try Data("x".utf8).write(to: file)
        guard case .unreadableTarget = VerifyEngine.runXattr(folder: file) else {
            return XCTFail("a file is not a folder to walk")
        }
    }

    func testUnreadableFolderIsAnUnreadableTarget() throws {
        let root = try freshTempDir()
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try writeStamped("locked/a.bin", content: "one", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        // Running as root defeats permission checks entirely; skip rather than
        // assert something the environment can't produce.
        try XCTSkipIf(getuid() == 0, "permissions do not constrain root")

        guard case .unreadableTarget = VerifyEngine.runXattr(folder: locked) else {
            return XCTFail("a folder we cannot read must never report success")
        }
    }

    func testReadableFolderWithNothingStampedIsStillAReport() throws {
        let root = try freshTempDir()
        try Data("plain".utf8).write(to: root.appendingPathComponent("b.bin"))
        guard case .report(let r) = VerifyEngine.runXattr(folder: root) else {
            return XCTFail("a readable folder holding nothing stamped is not an error")
        }
        XCTAssertEqual(r.total, 0)
    }
}
