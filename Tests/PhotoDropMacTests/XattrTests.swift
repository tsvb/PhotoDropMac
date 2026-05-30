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

    func testVerifiesStampedFiles() throws {
        let root = try freshTempDir()
        try writeStamped("2026/a.bin", content: "one", in: root)
        try writeStamped("2026/b.bin", content: "two", in: root)
        let report = try XCTUnwrap(VerifyEngine.runXattr(folder: root))
        XCTAssertTrue(report.allGood)
        XCTAssertEqual(report.verified, 2)
    }

    func testReportsChangedStampedFile() throws {
        let root = try freshTempDir()
        let a = try writeStamped("a.bin", content: "one", in: root)
        try Data("CHANGED".utf8).write(to: a)   // content edited; stamped digest now stale
        let report = try XCTUnwrap(VerifyEngine.runXattr(folder: root))
        XCTAssertEqual(report.changed, 1)
        XCTAssertEqual(report.verified, 0)
    }

    func testIgnoresUnstampedFiles() throws {
        let root = try freshTempDir()
        try writeStamped("a.bin", content: "one", in: root)
        try Data("plain".utf8).write(to: root.appendingPathComponent("b.bin"))   // no xattr
        let report = try XCTUnwrap(VerifyEngine.runXattr(folder: root))
        XCTAssertEqual(report.total, 1, "only the stamped file is checked")
        XCTAssertTrue(report.allGood)
    }

    func testEmptyWhenNothingStamped() throws {
        let root = try freshTempDir()
        try Data("plain".utf8).write(to: root.appendingPathComponent("b.bin"))
        XCTAssertEqual(try XCTUnwrap(VerifyEngine.runXattr(folder: root)).total, 0)
    }
}
