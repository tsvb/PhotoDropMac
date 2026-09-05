import XCTest
@testable import PhotoDropMac

/// `SyncEngine` — the one command that writes to a destination without a card.
///
/// It shipped with no tests at all: measured, 0 of 169 lines covered, for the
/// path that copies files into a mirror on the strength of a manifest and then
/// writes that mirror a manifest of its own. Every rule the type comment states
/// is pinned here, each with the failure it prevents.
final class SyncEngineTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @discardableResult
    private func writeFile(_ relPath: String, content: String, in root: URL) throws -> String {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return String(format: "%016llx", try XxHash64.hash(fileAt: url))
    }

    private func entry(_ path: String, hash: String) -> ManifestEntry {
        ManifestEntry(name: (path as NSString).lastPathComponent, path: path, bytes: 0,
                      xxhash64: hash, status: "verified")
    }

    /// An ingest's manifest at `library`, recording `destinations` as the roots
    /// that job wrote.
    private func writeManifest(into library: URL, destinations: [URL]? = nil, _ entries: [ManifestEntry]) throws {
        let stamp = Date(timeIntervalSince1970: 1_716_000_000)
        let roots = destinations ?? [library]
        let manifest = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName, createdAt: stamp, source: nil,
            primaryDestination: library.path(percentEncoded: false),
            archiveDestination: roots.count > 1 ? roots[1].path(percentEncoded: false) : nil,
            destinations: roots.map { $0.path(percentEncoded: false) },
            verified: true, partial: false, filesCopied: entries.count, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: entries)
        XCTAssertNotNil(ManifestWriter.write(manifest, intoRoot: library, stamp: stamp))
    }

    /// A two-file library with an honest manifest, and an empty mirror.
    private func makeLibrary() throws -> (library: URL, mirror: URL, hashes: [String: String]) {
        let tmp = try freshTempDir()
        let library = tmp.appendingPathComponent("library", isDirectory: true)
        let mirror = tmp.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        let a = try writeFile("2026/2026-05-28/IMG_0001.CR2", content: "first photo", in: library)
        let b = try writeFile("2026/2026-05-28/IMG_0002.CR2", content: "second photo", in: library)
        let hashes = ["2026/2026-05-28/IMG_0001.CR2": a, "2026/2026-05-28/IMG_0002.CR2": b]
        try writeManifest(into: library, hashes.map { entry($0.key, hash: $0.value) })
        return (library, mirror, hashes)
    }

    private func decodedManifest(at url: URL?) throws -> Manifest {
        let data = try Data(contentsOf: XCTUnwrap(url))
        return try XCTUnwrap(ManifestWriter.decode(data), "the sync manifest must decode as a manifest")
    }

    // MARK: - The happy path, and what makes it verifiable

    func testCopiesWhatTheMirrorIsMissingAndMakesItVerifiableOnItsOwn() throws {
        let (library, mirror, hashes) = try makeLibrary()

        let outcome = try SyncEngine.run(library: library, mirror: mirror)

        XCTAssertEqual(outcome.copied, 2)
        XCTAssertEqual(outcome.alreadyPresent, 0)
        XCTAssertTrue(outcome.allGood)
        XCTAssertFalse(outcome.cancelled)
        for (relPath, hash) in hashes {
            let copy = mirror.appendingPathComponent(relPath)
            XCTAssertEqual(String(format: "%016llx", try XxHash64.hash(fileAt: copy)), hash,
                           "\(relPath) must land byte-identical")
        }
        // The mirror gets a manifest of its own — that is what lets
        // `verify <mirror>` say anything at all. Its record must be honest.
        let manifest = try decodedManifest(at: outcome.manifestURL)
        XCTAssertEqual(manifest.partial, false)
        XCTAssertEqual(manifest.filesCopied, 2)
        let report = try XCTUnwrap(VerifyEngine.run(target: mirror))
        XCTAssertTrue(report.allGood, "a synced mirror must verify on its own: \(report.issues)")
        XCTAssertEqual(report.verified, 2)
    }

    func testAlreadyPresentMatchingFilesAreVerifiedAndLeftAlone() throws {
        let (library, mirror, _) = try makeLibrary()
        try writeFile("2026/2026-05-28/IMG_0001.CR2", content: "first photo", in: mirror)
        let existing = mirror.appendingPathComponent("2026/2026-05-28/IMG_0001.CR2")
        let before = try XCTUnwrap(existing.resourceValues(forKeys: [.contentModificationDateKey])
                                    .contentModificationDate)

        let outcome = try SyncEngine.run(library: library, mirror: mirror)

        XCTAssertEqual(outcome.copied, 1)
        XCTAssertEqual(outcome.alreadyPresent, 1)
        XCTAssertTrue(outcome.allGood)
        let after = try XCTUnwrap(existing.resourceValues(forKeys: [.contentModificationDateKey])
                                   .contentModificationDate)
        XCTAssertEqual(before, after, "a file that already matches is never rewritten")
        // The mirror's manifest still records the file it did not copy, so
        // `verify <mirror>` covers the whole mirror, not just this run's work.
        XCTAssertEqual(try decodedManifest(at: outcome.manifestURL).files.count, 2)
    }

    // MARK: - The rule that matters: it only ever adds

    func testAFileWithDifferentContentAtTheMirrorIsReportedAndNeverOverwritten() throws {
        let (library, mirror, _) = try makeLibrary()
        let conflicting = mirror.appendingPathComponent("2026/2026-05-28/IMG_0001.CR2")
        try writeFile("2026/2026-05-28/IMG_0001.CR2", content: "something else entirely", in: mirror)

        let outcome = try SyncEngine.run(library: library, mirror: mirror)

        XCTAssertEqual(outcome.conflicting, ["2026/2026-05-28/IMG_0001.CR2"])
        XCTAssertFalse(outcome.allGood)
        XCTAssertEqual(outcome.copied, 1, "the other file still syncs — one conflict does not stop the run")
        XCTAssertEqual(String(data: try Data(contentsOf: conflicting), encoding: .utf8),
                       "something else entirely",
                       "two disagreeing copies is where picking a winner kills the good one")
        // The manifest is written (something changed) and says the mirror is
        // not a complete copy of the library.
        XCTAssertEqual(try decodedManifest(at: outcome.manifestURL).partial, true)
    }

    func testAFileMissingFromTheLibraryItselfIsReportedNotInvented() throws {
        let (library, mirror, _) = try makeLibrary()
        try FileManager.default.removeItem(at: library.appendingPathComponent("2026/2026-05-28/IMG_0002.CR2"))

        let outcome = try SyncEngine.run(library: library, mirror: mirror)

        XCTAssertEqual(outcome.missingAtSource, ["2026/2026-05-28/IMG_0002.CR2"])
        XCTAssertFalse(outcome.allGood, "a library missing its own files is a job for heal, and must not read as a clean sync")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: mirror.appendingPathComponent("2026/2026-05-28/IMG_0002.CR2").path))
    }

    /// The library's copy is the source, and it is trusted only because its
    /// manifest vouches for it. When the two disagree, propagating the file
    /// would spread damage into the one place that might still have had a good
    /// copy.
    func testALibraryCopyThatNoLongerMatchesItsManifestIsNotMirrored() throws {
        let (library, mirror, _) = try makeLibrary()
        try Data("bit rot".utf8).write(to: library.appendingPathComponent("2026/2026-05-28/IMG_0001.CR2"))

        let outcome = try SyncEngine.run(library: library, mirror: mirror)

        XCTAssertEqual(outcome.conflicting, ["2026/2026-05-28/IMG_0001.CR2"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: mirror.appendingPathComponent("2026/2026-05-28/IMG_0001.CR2").path),
            "the damaged bytes must not be left at the mirror")
        XCTAssertEqual(outcome.copied, 1)
    }

    // MARK: - Stopping

    /// A cancel stops at a file boundary, leaves no partial behind, and writes
    /// the mirror's manifest for what landed — marked partial. Before the CLI
    /// wired signals to this, a Ctrl-C killed the process mid-file, and the
    /// truncated file it left was reported by the *next* sync as a CONFLICT it
    /// must never touch.
    func testCancelStopsAtAFileBoundaryAndRecordsAPartialManifest() throws {
        let (library, mirror, _) = try makeLibrary()
        let landed = LandedCounter()

        let outcome = try SyncEngine.run(
            library: library, mirror: mirror,
            isCancelled: { landed.count >= 1 },
            onLog: { entry in if entry.kind == .verified || entry.kind == .copied { landed.increment() } })

        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.copied, 1)
        XCTAssertTrue(outcome.failed.isEmpty, "a cancel is not a failure")
        let manifest = try decodedManifest(at: outcome.manifestURL)
        XCTAssertEqual(manifest.partial, true, "the mirror is known to be incomplete and its record must say so")
        XCTAssertEqual(manifest.files.count, 1)
        // Nothing half-written: every file at the mirror is one the manifest vouches for.
        let onDisk = try FileManager.default.contentsOfDirectory(
            at: mirror.appendingPathComponent("2026/2026-05-28"), includingPropertiesForKeys: nil)
        XCTAssertEqual(onDisk.count, 1)
        XCTAssertTrue(try XCTUnwrap(VerifyEngine.run(target: mirror)).allGood)
    }

    func testANoOpSyncWritesNoSecondManifest() throws {
        let (library, mirror, _) = try makeLibrary()
        let first = try SyncEngine.run(library: library, mirror: mirror)
        XCTAssertNotNil(first.manifestURL)

        let second = try SyncEngine.run(library: library, mirror: mirror)

        XCTAssertEqual(second.copied, 0)
        XCTAssertEqual(second.alreadyPresent, 2)
        XCTAssertTrue(second.allGood)
        XCTAssertNil(second.manifestURL, "a nightly no-op must not fill the folder with identical manifests")
        XCTAssertEqual(ManifestWriter.manifestURLs(near: mirror).count, 1)
    }

    // MARK: - What heal will do with the result

    func testKnowsWhetherTheLibraryRecordsThisMirror() throws {
        let (library, mirror, _) = try makeLibrary()
        let recorded = try SyncEngine.run(library: library, mirror: mirror)
        XCTAssertFalse(recorded.recordedInLibrary,
                       "an ingest that never wrote here cannot have recorded it — heal needs --mirror")

        // The same mirror, once a job's manifest names it — say a later ingest
        // that ran while it was mounted. Spelled with a trailing slash, which
        // must not read as a different folder.
        let tmp = try freshTempDir()
        let library2 = tmp.appendingPathComponent("library2", isDirectory: true)
        let mirror2 = tmp.appendingPathComponent("mirror2", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror2, withIntermediateDirectories: true)
        let h = try writeFile("2026/a.CR2", content: "a", in: library2)
        try writeManifest(into: library2,
                          destinations: [library2, URL(fileURLWithPath: mirror2.path + "/", isDirectory: true)],
                          [entry("2026/a.CR2", hash: h)])
        XCTAssertTrue(try SyncEngine.run(library: library2, mirror: mirror2).recordedInLibrary)
    }

    // MARK: - Refusals

    func testRefusesAMirrorThatDoesNotExist() throws {
        let (library, mirror, _) = try makeLibrary()
        try FileManager.default.removeItem(at: mirror)
        XCTAssertThrowsError(try SyncEngine.run(library: library, mirror: mirror)) { error in
            guard case SyncEngine.Refusal.mirrorMissing = error else {
                return XCTFail("expected mirrorMissing, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.path),
                       "a typo'd mirror must not become a brand-new library tree")
    }

    func testRefusesALibraryWithNoManifests() throws {
        let tmp = try freshTempDir()
        let library = tmp.appendingPathComponent("library", isDirectory: true)
        let mirror = tmp.appendingPathComponent("mirror", isDirectory: true)
        try writeFile("2026/a.CR2", content: "a", in: library)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SyncEngine.run(library: library, mirror: mirror)) { error in
            guard case SyncEngine.Refusal.noManifests = error else {
                return XCTFail("expected noManifests, got \(error)")
            }
        }
    }

    /// The same topology rule the ingest applies: a mirror inside the library
    /// would make every file match a copy of itself.
    func testRefusesAMirrorInsideTheLibrary() throws {
        let (library, _, _) = try makeLibrary()
        let nested = library.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SyncEngine.run(library: library, mirror: nested)) { error in
            guard case SyncEngine.Refusal.overlapping = error else {
                return XCTFail("expected overlapping, got \(error)")
            }
        }
    }
}

/// Counts landed files from the log callback so the cancel test can trip after
/// the first one. A class, because the engine's callbacks are non-escaping
/// closures that a `var` capture would race with under Swift 6's rules.
private final class LandedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
