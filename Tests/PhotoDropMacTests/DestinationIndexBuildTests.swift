import XCTest
@testable import PhotoDropMac

/// `DestinationIndex.build` and its incremental (snapshot-cached) path.
///
/// This is the riskiest previously-untested code in Core: the existing
/// `DestinationIndexTests` hand-construct `DestinationIndex(bySize:)` and only
/// exercise `findDuplicate`, so nothing covered how the index is actually
/// *built* — and **a false duplicate silently skips a photo**, with no digest
/// recorded for a later verify to catch it.
///
/// The store URL is injected on every call so these never touch the real
/// snapshot in Application Support.
final class DestinationIndexBuildTests: XCTestCase {

    private var tmp: URL!
    private var store: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DestIndexBuild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = tmp.appendingPathComponent("index.json")
        addTeardownBlock { [tmp] in try? FileManager.default.removeItem(at: tmp!) }
    }

    @discardableResult
    private func write(_ relPath: String, _ content: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// Compare on symlink-resolved paths. The dedup index stores URLs straight
    /// from `contentsOfDirectory`, which resolves `/var` → `/private/var`, while
    /// fixtures are built from the unresolved temp path. (The *collision* scan,
    /// `existingFilePaths`, deliberately reconstructs unresolved paths instead —
    /// it string-matches against planned destinations, where the difference is
    /// load-bearing. The dedup index never compares paths, only hashes.)
    private func allPaths(_ index: DestinationIndex) -> Set<String> {
        Set(index.bySize.values.flatMap { $0 }.map { $0.resolvingSymlinksInPath().path })
    }

    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    private func root(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Basics

    func testMissingRootYieldsEmptyIndex() {
        let index = DestinationIndex.build(at: tmp.appendingPathComponent("nope"), storeURL: store)
        XCTAssertTrue(index.bySize.isEmpty)
    }

    func testIndexesFilesBySizeAcrossSubdirectories() throws {
        let lib = try root("lib")
        try write("2026/a.bin", "12345", in: lib)          // 5 bytes
        try write("2026/05/b.bin", "12345", in: lib)       // 5 bytes, nested
        try write("2026/c.bin", "1234567890", in: lib)     // 10 bytes

        let index = DestinationIndex.build(at: lib, storeURL: store)
        XCTAssertEqual(index.bySize[5]?.count, 2, "both 5-byte files share a size bucket")
        XCTAssertEqual(index.bySize[10]?.count, 1)
        XCTAssertEqual(allPaths(index).count, 3)
    }

    func testDirectoriesAreNotIndexedAsFiles() throws {
        let lib = try root("lib")
        try write("2026/05/a.bin", "x", in: lib)
        let index = DestinationIndex.build(at: lib, storeURL: store)
        XCTAssertEqual(allPaths(index).count, 1, "only the regular file, not its two parent dirs")
    }

    // MARK: - The incremental path must agree with a cold build

    func testWarmBuildMatchesColdBuild() throws {
        let lib = try root("lib")
        try write("2026/a.bin", "aaaa", in: lib)
        try write("2026/05/b.bin", "bb", in: lib)

        let cold = DestinationIndex.build(at: lib, storeURL: store)      // writes the snapshot
        let warm = DestinationIndex.build(at: lib, storeURL: store)      // reads it back
        XCTAssertEqual(allPaths(cold), allPaths(warm),
                       "a cached scan must see exactly what a fresh scan sees")
        XCTAssertFalse(allPaths(warm).isEmpty)
    }

    /// The dangerous direction: a file that is gone must not survive in the
    /// index, or a later ingest would treat a new photo as already present.
    func testDeletedFileDoesNotSurviveInTheWarmIndex() throws {
        let lib = try root("lib")
        let doomed = try write("2026/a.bin", "aaaa", in: lib)
        try write("2026/keep.bin", "kkkk", in: lib)
        _ = DestinationIndex.build(at: lib, storeURL: store)

        try FileManager.default.removeItem(at: doomed)
        let warm = DestinationIndex.build(at: lib, storeURL: store)

        XCTAssertFalse(allPaths(warm).contains(resolved(doomed)),
                       "a deleted file must not linger in the cached index")
        XCTAssertTrue(allPaths(warm).contains(resolved(lib.appendingPathComponent("2026/keep.bin"))),
                      "…and the surviving file must still be there (so the check above isn't vacuous)")
        XCTAssertEqual(allPaths(warm).count, 1)
    }

    /// A change deep in the tree does not touch the *root's* mtime, so the
    /// incremental walk has to recurse into unchanged directories anyway. If it
    /// short-circuited, a newly added file would be invisible to dedup.
    func testFileAddedInAnUnchangedGrandchildIsStillSeen() throws {
        let lib = try root("lib")
        try write("2026/05/a.bin", "aaaa", in: lib)
        _ = DestinationIndex.build(at: lib, storeURL: store)

        let added = try write("2026/05/b.bin", "bbbbbb", in: lib)
        let warm = DestinationIndex.build(at: lib, storeURL: store)

        XCTAssertTrue(allPaths(warm).contains(resolved(added)),
                      "a grandchild addition must be picked up despite an unchanged root mtime")
    }

    func testSnapshotsForDifferentRootsDoNotClobberEachOther() throws {
        let a = try root("libA")
        let b = try root("libB")
        let fileA = try write("2026/a.bin", "aaaa", in: a)
        let fileB = try write("2026/b.bin", "bbbb", in: b)

        _ = DestinationIndex.build(at: a, storeURL: store)
        _ = DestinationIndex.build(at: b, storeURL: store)   // same store file
        let warmA = DestinationIndex.build(at: a, storeURL: store)

        XCTAssertTrue(allPaths(warmA).contains(resolved(fileA)))
        XCTAssertFalse(allPaths(warmA).contains(resolved(fileB)),
                       "one root's snapshot must not leak into another's index")
    }

    func testCorruptSnapshotStoreDegradesToAFullWalk() throws {
        let lib = try root("lib")
        let file = try write("2026/a.bin", "aaaa", in: lib)
        try Data("not json at all".utf8).write(to: store)

        let index = DestinationIndex.build(at: lib, storeURL: store)
        XCTAssertTrue(allPaths(index).contains(resolved(file)),
                      "an unreadable snapshot must fall back to scanning, not to an empty index")
    }

    // MARK: - The property that makes a stale index safe

    /// The index is only a *candidate* filter: `findDuplicate` re-hashes the
    /// candidate's real bytes before declaring a match. That separation is why a
    /// stale size in the snapshot can cause a missed dedup (harmless — the file
    /// is copied again) but never a false duplicate (which would silently drop a
    /// photo). Rewrite a destination file in place, keeping its size, and the
    /// old content must no longer match.
    func testStaleIndexEntryCannotProduceAFalseDuplicate() async throws {
        let lib = try root("lib")
        let dest = try write("2026/a.bin", "AAAA", in: lib)
        let index = DestinationIndex.build(at: lib, storeURL: store)

        // Same size, different bytes — the index still points at this URL.
        try Data("BBBB".utf8).write(to: dest)

        let source = try write("card/a.bin", "AAAA", in: tmp)   // matches the *old* content
        let cache = HashCache(storeURL: tmp.appendingPathComponent("cache.json"))
        let match = await index.findDuplicate(sourceSize: 4, sourceVolumeID: "vol",
                                              sourceURL: source, using: cache)

        XCTAssertNil(match, "a duplicate is decided on real bytes, never on the cached size alone")
    }
}
