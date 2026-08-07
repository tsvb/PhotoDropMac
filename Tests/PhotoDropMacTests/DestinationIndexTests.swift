import XCTest
@testable import PhotoDropMac

/// Dedup semantics for `DestinationIndex.findDuplicate`: identical content is
/// detected, different content of the same size is not, and zero-byte files are
/// never treated as duplicates (§1.4 — they'd otherwise all collide on size 0 +
/// the empty-input hash and a distinct empty companion would be dropped).
final class DestinationIndexTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ data: Data, named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func cache(in dir: URL) -> HashCache {
        HashCache(storeURL: dir.appendingPathComponent("cache.json"))
    }

    func testIdenticalContentIsDetectedAsDuplicate() async throws {
        let dir = try freshTempDir()
        let content = Data("the same bytes".utf8)
        let existing = try write(content, named: "existing.bin", in: dir)
        let source = try write(content, named: "source.bin", in: dir)
        let index = DestinationIndex(bySize: [Int64(content.count): [existing]])

        let dup = await index.findDuplicate(sourceSize: Int64(content.count),
                                            sourceVolumeID: "vol", sourceURL: source, using: cache(in: dir))
        XCTAssertEqual(dup?.url, existing)
        // The digest the match was made on comes back with it: the manifest entry
        // for a skipped file needs it, and recomputing it later would mean
        // re-reading a file we have already hashed.
        XCTAssertEqual(dup?.hash, try XxHash64.hash(fileAt: existing))
    }

    func testDifferentContentSameSizeIsNotDuplicate() async throws {
        let dir = try freshTempDir()
        let existing = try write(Data("AAAAAAAA".utf8), named: "existing.bin", in: dir)
        let source = try write(Data("BBBBBBBB".utf8), named: "source.bin", in: dir)   // same size, different bytes
        let index = DestinationIndex(bySize: [8: [existing]])

        let dup = await index.findDuplicate(sourceSize: 8, sourceVolumeID: "vol",
                                            sourceURL: source, using: cache(in: dir))
        XCTAssertNil(dup)
    }

    func testZeroByteFilesAreNeverDeduplicated() async throws {
        let dir = try freshTempDir()
        let existingEmpty = try write(Data(), named: "existing.xmp", in: dir)
        let sourceEmpty = try write(Data(), named: "source.wav", in: dir)
        let index = DestinationIndex(bySize: [0: [existingEmpty]])

        let dup = await index.findDuplicate(sourceSize: 0, sourceVolumeID: "vol",
                                            sourceURL: sourceEmpty, using: cache(in: dir))
        XCTAssertNil(dup, "a zero-byte file must always be copied, never skipped as a duplicate")
    }
}
