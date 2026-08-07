import XCTest
@testable import PhotoDropMac

/// Overlapping trees — a destination that contains the source, or a mirror that
/// contains another destination.
///
/// **Threat model.** The destination is user-typed configuration (a free-form
/// `TextField` in Settings, an `NSOpenPanel` that reaches `/Volumes/`, or `--to`
/// on the command line), and nothing validated it against the source or against
/// the other destinations. `DestinationIndex.findDuplicate` matches content
/// *anywhere under a destination root* by design, so an overlap makes every file
/// a duplicate of itself.
///
/// **Measured before-state.** With the source inside the destination:
/// `filesCopied == 0`, `filesFailed == 0`, `haltReason == nil`, every file logged
/// `already present as <its own name>`, a manifest written whose entries point at
/// the *source* files, the CLI exiting 0 — and the app then ejecting the card,
/// because the eject was gated on halt/cancel and on nothing else. The user is
/// told "Ingest complete" and holds a card that was never copied.
final class DestinationTopologyTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DestinationTopologyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func dir(_ path: String, in tmp: URL) throws -> URL {
        let url = tmp.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBundle(_ name: String, in card: URL) throws -> AssetBundle {
        let url = card.appendingPathComponent(name)
        try Data(repeating: 0x42, count: 4096).write(to: url)
        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 28; c.hour = 12
        let photo = ScannedPhoto(id: url, url: url, size: 4096,
                                 dateTaken: Calendar.current.date(from: c)!,
                                 dateSource: .fileModification)
        return AssetBundle(primary: photo, companions: [])
    }

    private func ingest(_ bundles: [AssetBundle], primary: URL, archives: [URL] = [],
                        source: String?, tmp: URL) async -> (CopyResult, [LogEntry]) {
        final class Sink: @unchecked Sendable { var logs: [LogEntry] = [] }
        let sink = Sink()
        let engine = IngestEngine(
            bundles: bundles, description: "", primaryRoot: primary, archiveRoots: archives,
            verify: true, ejectAfter: false, sourceMountPoint: source, sourceVolumeID: "test-vol",
            template: .default, cardLabel: "",
            cache: HashCache(storeURL: tmp.appendingPathComponent("cache-\(UUID()).json")),
            indexStoreURL: tmp.appendingPathComponent("index-\(UUID()).json"),
            logDirectory: tmp.appendingPathComponent("Logs", isDirectory: true),
            onLog: { sink.logs.append($0) })
        return (await engine.run(), sink.logs)
    }

    // MARK: - The predicate

    func testContainmentComparesComponentsNotStringPrefixes() throws {
        let tmp = try freshTempDir()
        let library = try dir("Library", in: tmp)
        let sibling = try dir("Library2", in: tmp)
        let inner = try dir("Library/2026", in: tmp)

        XCTAssertTrue(DestinationTopology.contains(library, inner))
        XCTAssertFalse(DestinationTopology.contains(library, sibling),
                       "“Library2” is a sibling of “Library”, not a child — a raw hasPrefix says otherwise")
        XCTAssertFalse(DestinationTopology.contains(library, library),
                       "a root does not contain itself; identical roots are ArchiveDestinations' job")
        XCTAssertFalse(DestinationTopology.contains(inner, library))
    }

    func testTrailingSlashAndDotSpellingsDoNotHideContainment() throws {
        let tmp = try freshTempDir()
        _ = try dir("Library/2026", in: tmp)
        let spelledOddly = URL(fileURLWithPath: tmp.path + "/Library/./2026/", isDirectory: true)
        XCTAssertTrue(DestinationTopology.contains(tmp.appendingPathComponent("Library"), spelledOddly))
    }

    func testSymlinkedDestinationIsRecognisedAsTheSameTree() throws {
        let tmp = try freshTempDir()
        let real = try dir("Library", in: tmp)
        _ = try dir("Library/2026", in: tmp)
        let link = tmp.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertTrue(DestinationTopology.contains(link, real.appendingPathComponent("2026")),
                      "a symlinked mirror really does name the same tree")
    }

    func testCheckReportsEachOverlapKind() throws {
        let tmp = try freshTempDir()
        let library = try dir("Library", in: tmp)
        let card = try dir("Library/card", in: tmp)
        let backup = try dir("Library/Backup", in: tmp)

        let sourceInside = DestinationTopology.check(source: card, roots: [library])
        XCTAssertEqual(sourceInside, [.sourceInsideDestination(source: card, destination: library)])

        let nested = DestinationTopology.check(source: nil, roots: [library, backup])
        XCTAssertEqual(nested, [.nestedDestinations(outer: library, inner: backup)])

        // Order-independent: naming the inner root first must still report it.
        let reversed = DestinationTopology.check(source: nil, roots: [backup, library])
        XCTAssertEqual(reversed, [.nestedDestinations(outer: library, inner: backup)])

        let destInsideSource = DestinationTopology.check(source: library, roots: [backup])
        XCTAssertEqual(destInsideSource, [.destinationInsideSource(destination: backup, source: library)])

        XCTAssertTrue(DestinationTopology.check(source: card, roots: [try dir("Elsewhere", in: tmp)]).isEmpty,
                      "disjoint trees are the normal case and must not be flagged")
    }

    // MARK: - The engine refuses

    /// The headline case. Before: 0 copied, 0 failed, no halt, a manifest
    /// attesting to the source files, and an eject.
    func testSourceInsideDestinationIsRefusedBeforeAnythingIsCopied() async throws {
        let tmp = try freshTempDir()
        let library = try dir("Library", in: tmp)
        let card = try dir("Library/card", in: tmp)
        let bundles = [try makeBundle("IMG_0001.JPG", in: card)]

        let (result, logs) = await ingest(bundles, primary: library, source: card.path, tmp: tmp)

        XCTAssertTrue(result.halted, "an overlap must halt, not report a clean all-duplicate job")
        XCTAssertEqual(result.filesCopied, 0)
        XCTAssertEqual(result.filesSkipped, 0, "refused means refused — not 'skipped as duplicates'")
        XCTAssertFalse(result.wasEjected, "never eject a card whose photos were not copied")
        XCTAssertNil(result.manifestURL, "no bytes landed, so there is nothing to attest to")
        XCTAssertTrue(logs.contains { $0.kind == .error && $0.line.contains("is inside the destination") },
                      "the log names the overlap: \(logs.map(\.line))")

        // Nothing was written into the library beyond the card folder itself.
        let year = library.appendingPathComponent("2026", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: year.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: library.appendingPathComponent(ManifestWriter.folderName).path))
    }

    /// A mirror that contains the primary. From run 2 onward the mirror's index
    /// walked into the primary and skipped every write as a duplicate, so adding
    /// a parent folder as a mirror left it empty forever while reporting success.
    func testMirrorContainingThePrimaryIsRefused() async throws {
        let tmp = try freshTempDir()
        let outer = try dir("Vol", in: tmp)
        let library = try dir("Vol/Lib", in: tmp)
        let card = try dir("card", in: tmp)
        let bundles = [try makeBundle("IMG_0001.JPG", in: card)]

        let (result, logs) = await ingest(bundles, primary: library, archives: [outer],
                                          source: card.path, tmp: tmp)

        XCTAssertTrue(result.halted)
        XCTAssertEqual(result.haltReason, "one destination folder is inside another")
        XCTAssertTrue(logs.contains { $0.line.contains("not independent copies") },
                      "the message has to say *why*, or it reads as a spurious restriction")
    }

    /// The child direction: a mirror inside the primary. Culling the library then
    /// made the *primary* write skip in favour of the copy under the mirror, and
    /// the manifest re-pointed the photo into the backup subfolder — a path that
    /// resolves cleanly under the library root, so `verify` reported health.
    func testMirrorInsideThePrimaryIsRefused() async throws {
        let tmp = try freshTempDir()
        let library = try dir("Lib", in: tmp)
        let backup = try dir("Lib/Backup", in: tmp)
        let card = try dir("card", in: tmp)
        let bundles = [try makeBundle("IMG_0001.JPG", in: card)]

        let (result, _) = await ingest(bundles, primary: library, archives: [backup],
                                       source: card.path, tmp: tmp)
        XCTAssertTrue(result.halted)
        XCTAssertEqual(result.filesCopied, 0)
    }

    /// Disjoint trees are untouched — the guard must not cost the normal case.
    func testDisjointDestinationsRunNormally() async throws {
        let tmp = try freshTempDir()
        let library = try dir("Lib", in: tmp)
        let mirror = try dir("Mirror", in: tmp)
        let card = try dir("card", in: tmp)
        let bundles = [try makeBundle("IMG_0001.JPG", in: card)]

        let (result, _) = await ingest(bundles, primary: library, archives: [mirror],
                                       source: card.path, tmp: tmp)
        XCTAssertFalse(result.halted)
        XCTAssertEqual(result.filesCopied, 2, "one file at each of two destinations")
    }
}
