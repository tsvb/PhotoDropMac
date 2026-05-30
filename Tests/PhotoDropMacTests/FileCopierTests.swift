import XCTest
@testable import PhotoDropMac

/// Exercises the copy engine's data-safety guarantees against a real temp
/// directory. The headline cases are the overwrite-refusal regression tests
/// for the `O_EXCL` exclusive-create fix — the core "nothing is ever
/// overwritten" invariant.
final class FileCopierTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func write(_ string: String, to url: URL) throws { try Data(string.utf8).write(to: url) }
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    // MARK: - Overwrite protection (regression for the O_EXCL exclusive create)

    func testRefusesToOverwriteExistingFile() throws {
        let source = tmp.appendingPathComponent("source.bin")
        let dest = tmp.appendingPathComponent("dest.bin")
        try write("NEW CONTENT FROM CARD", to: source)
        try write("ORIGINAL IRREPLACEABLE PHOTO", to: dest)

        XCTAssertThrowsError(
            try FileCopier.copyAndHash(source: source, destination: dest, onProgress: { _ in })
        ) { error in
            guard case FileCopierError.destinationExists(let u) = error else {
                return XCTFail("expected .destinationExists, got \(error)")
            }
            XCTAssertEqual(u, dest)
        }
        XCTAssertEqual(read(dest), "ORIGINAL IRREPLACEABLE PHOTO",
                       "the existing file must be byte-for-byte intact after a refused overwrite")
    }

    func testCaseVariantNameNeverDestroysExistingFile() throws {
        // On a case-insensitive volume (APFS/HFS+ default) a case-variant name
        // maps to the same file and must be refused; on a case-sensitive volume
        // it is a genuinely different path and copies. Either way the
        // pre-existing file must survive untouched — that's the invariant.
        let source = tmp.appendingPathComponent("source.bin")
        let existing = tmp.appendingPathComponent("Photo.bin")
        let variant = tmp.appendingPathComponent("PHOTO.bin")
        try write("DIFFERENT BYTES", to: source)
        try write("EXISTING FRAME", to: existing)

        let caseInsensitive = FileManager.default.fileExists(atPath: variant.path)
        do {
            _ = try FileCopier.copyAndHash(source: source, destination: variant, onProgress: { _ in })
            XCTAssertFalse(caseInsensitive, "a case-insensitive volume should have refused the variant write")
        } catch FileCopierError.destinationExists {
            XCTAssertTrue(caseInsensitive, "only a case-insensitive volume should treat the variant as existing")
        }
        XCTAssertEqual(read(existing), "EXISTING FRAME", "the pre-existing file must never be destroyed")
    }

    // MARK: - Happy path

    func testFreshCopySucceedsAndTeeHashMatches() throws {
        let source = tmp.appendingPathComponent("source.bin")
        let dest = tmp.appendingPathComponent("nested/dir/dest.bin")   // also exercises directory creation
        let payload = String(repeating: "The quick brown fox. ", count: 5000)
        try write(payload, to: source)

        let teeHash = try FileCopier.copyAndHash(source: source, destination: dest, onProgress: { _ in })

        XCTAssertEqual(read(dest), payload)
        XCTAssertEqual(teeHash, try XxHash64.hash(fileAt: source), "tee-hash must equal the source digest")
        XCTAssertEqual(teeHash, try XxHash64.hash(fileAt: dest), "tee-hash must equal the destination digest")
    }

    func testProgressSumsToExactlyFileSize() throws {
        let source = tmp.appendingPathComponent("source.bin")
        let dest = tmp.appendingPathComponent("dest.bin")
        let byteCount = (1 << 20) * 3 + 12_345   // a few full chunks plus a remainder
        try Data(repeating: 0xAB, count: byteCount).write(to: source)

        var reported: Int64 = 0
        _ = try FileCopier.copyAndHash(source: source, destination: dest) { reported += $0 }
        XCTAssertEqual(reported, Int64(byteCount), "every byte must be reported exactly once")
    }

    // MARK: - No orphan when the copy can't proceed

    func testMissingSourceThrowsAndWritesNoDestination() throws {
        let source = tmp.appendingPathComponent("does-not-exist.bin")
        let dest = tmp.appendingPathComponent("dest.bin")
        XCTAssertThrowsError(
            try FileCopier.copyAndHash(source: source, destination: dest, onProgress: { _ in })
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "a failed copy must not leave a destination file behind")
    }

    // MARK: - Mid-file cancellation (regression for the explicit cancel signal)

    func testMidFileCancellationAbortsAndRemovesPartial() throws {
        let source = tmp.appendingPathComponent("big.bin")
        let dest = tmp.appendingPathComponent("dest.bin")
        // Several 1 MiB chunks so cancellation lands mid-file, not at the start.
        try Data(repeating: 0x5A, count: (1 << 20) * 4).write(to: source)

        // Let the first chunk through, then report cancelled.
        var checks = 0
        XCTAssertThrowsError(
            try FileCopier.copyAndHash(source: source, destination: dest,
                                       isCancelled: { checks += 1; return checks > 1 },
                                       onProgress: { _ in })
        ) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "a cancelled copy must not leave a partial file behind")
    }

    func testAlwaysFalseCancellationFlagDoesNotInterfere() throws {
        // A flag that never trips must leave a normal copy untouched.
        let source = tmp.appendingPathComponent("s.bin")
        let dest = tmp.appendingPathComponent("d.bin")
        try Data(repeating: 0x11, count: (1 << 20) * 2).write(to: source)
        let hash = try FileCopier.copyAndHash(source: source, destination: dest,
                                              isCancelled: { false }, onProgress: { _ in })
        XCTAssertEqual(hash, try XxHash64.hash(fileAt: source))
        XCTAssertEqual(hash, try XxHash64.hash(fileAt: dest))
    }

    // MARK: - Verification

    func testVerifyAcceptsMatchAndRejectsMismatch() throws {
        let file = tmp.appendingPathComponent("f.bin")
        try write("hello world", to: file)
        let good = try XxHash64.hash(fileAt: file)
        XCTAssertNoThrow(try FileCopier.verify(file: file, expectedHash: good))
        XCTAssertThrowsError(try FileCopier.verify(file: file, expectedHash: good ^ 0xFFFF)) { error in
            guard case FileCopierError.verificationMismatch = error else {
                return XCTFail("expected .verificationMismatch, got \(error)")
            }
        }
    }
}
