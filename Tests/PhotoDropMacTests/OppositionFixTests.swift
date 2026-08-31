import XCTest
@testable import PhotoDropMac

/// Regression tests for the findings of the opposition-analysis pass.
///
/// Each one pins a rule the app already stated somewhere and was not enforcing
/// at one particular sink. They are grouped here rather than scattered into the
/// existing suites because the *pattern* is the point: "couldn't read it must
/// never be reported as nothing there" failed the same way in six places, and a
/// future sink is likelier to be caught by a reader who sees them together.
final class OppositionFixTests: XCTestCase {

    // MARK: - Helpers

    private func freshTempDir(_ label: String = "Opposition") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @discardableResult
    private func write(_ data: Data, named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    // MARK: - F1 · the dedup skip must read the file it vouches for

    /// **The top finding.** `HashCache.destinationHash` answers from the persisted
    /// cache whenever `stat` still agrees on (size, mtime, birthtime), so on a warm
    /// cache nothing read the destination file that a dedup skip is a claim about.
    ///
    /// Silent corruption — bit rot, a bad cable, a partial restore — changes content
    /// without touching any of those three. Before the fix, a file that rotted after
    /// its ingest matched its own stale digest: the copy was skipped, a *fresh*
    /// manifest entry recorded that digest for that path, and the user wiped the card.
    ///
    /// Simulated exactly: seed the cache with the digest the file used to have, then
    /// rewrite its bytes and restore its timestamps so the cache still validates.
    func testDedupRefusesAMatchWhoseBytesNoLongerAgreeWithTheCache() async throws {
        let dir = try freshTempDir("DedupReread")
        let good = Data("the bytes that were ingested".utf8)
        let rotted = Data("the bytes that are there now".utf8)   // same length
        XCTAssertEqual(good.count, rotted.count, "the scenario needs an identical size")

        let existing = try write(good, named: "existing.cr2", in: dir)
        let source = try write(good, named: "source.cr2", in: dir)

        let cache = HashCache(storeURL: dir.appendingPathComponent("cache.json"))
        // The digest recorded at ingest time, when the file really did hold `good`.
        await cache.recordDestination(url: existing, hash: try XxHash64.hash(fileAt: existing))

        // Corrupt in place, preserving the timestamps the cache validates against —
        // which is what silent corruption looks like from `stat`'s point of view.
        let before = try FileManager.default.attributesOfItem(atPath: existing.path)
        try rotted.write(to: existing)
        try FileManager.default.setAttributes(
            [.modificationDate: before[.modificationDate] as Any,
             .creationDate: before[.creationDate] as Any],
            ofItemAtPath: existing.path)

        let index = DestinationIndex(bySize: [Int64(good.count): [existing]])
        let dup = await index.findDuplicate(sourceSize: Int64(good.count),
                                            sourceVolumeID: "vol", sourceURL: source, using: cache)

        XCTAssertNil(dup, """
            A dedup skip is a promise that an identical copy is already on disk. \
            The cached digest said so; the file's real bytes did not. Skipping here \
            would have written a manifest vouching for a corrupt file and let the \
            user wipe the only good copy.
            """)

        // And the poisoned entry is dropped rather than left to make the same
        // wrong call on the next run: re-asking recomputes from the file.
        let rehashed = await cache.destinationHash(url: existing)
        XCTAssertEqual(rehashed, try XxHash64.hash(fileAt: existing))
    }

    /// The fix must not cost a read on every candidate — only on the one that
    /// actually matches. A same-size non-match is still settled by the cache.
    func testAGenuineDuplicateIsStillDetected() async throws {
        let dir = try freshTempDir("DedupStillWorks")
        let content = Data("identical content here".utf8)
        let existing = try write(content, named: "existing.cr2", in: dir)
        let source = try write(content, named: "source.cr2", in: dir)
        let cache = HashCache(storeURL: dir.appendingPathComponent("cache.json"))
        let index = DestinationIndex(bySize: [Int64(content.count): [existing]])

        let dup = await index.findDuplicate(sourceSize: Int64(content.count),
                                            sourceVolumeID: "vol", sourceURL: source, using: cache)
        XCTAssertEqual(dup?.url, existing)
        XCTAssertEqual(dup?.hash, try XxHash64.hash(fileAt: existing))
    }

    // MARK: - F3 · the scan counts what it will not take

    /// A card of stills and clips scanned "clean": the extension filter dropped
    /// every movie with no tally, so the job planned the stills, passed the
    /// `filesFailed == 0` eject gate, wrote a manifest attesting to completeness,
    /// and ejected the only copy of the video.
    func testUnrecognizedFilesAreCountedAndBlockCompleteness() throws {
        let card = try freshTempDir("UnrecognizedScan")
        let dcim = card.appendingPathComponent("DCIM", isDirectory: true)
        try write(Data(repeating: 0x11, count: 256), named: "IMG_0001.CR2", in: dcim)
        try write(Data(repeating: 0x22, count: 256), named: "SHOT.rmf", in: dcim)      // unknown
        try write(Data(repeating: 0x33, count: 256), named: "NOTES.pages", in: dcim)   // unknown

        let outcome = AssetDiscovery.scanOutcome(root: card)
        XCTAssertEqual(outcome.bundles.count, 1)
        XCTAssertEqual(outcome.unrecognizedFiles, 2)
        XCTAssertFalse(outcome.isComplete, """
            A card still holding files this ingest will not copy has not been fully \
            taken, and no caller may eject on the strength of it — ejecting is this \
            app's "the card is finished" gesture and the next thing that happens to \
            a finished card is a format.
            """)
    }

    /// Camera and filesystem bookkeeping must not trip the tally, or the warning
    /// fires on every card and stops meaning anything.
    func testCameraBookkeepingIsNotCountedAsUnrecognized() throws {
        let card = try freshTempDir("BookkeepingScan")
        let dcim = card.appendingPathComponent("DCIM", isDirectory: true)
        try write(Data(repeating: 0x11, count: 256), named: "IMG_0001.CR2", in: dcim)
        try write(Data("x".utf8), named: "MISC.CTG", in: dcim)
        try write(Data("x".utf8), named: "IMG_0001.THM", in: dcim)
        try write(Data("x".utf8), named: "INDEX.BDM", in: dcim)

        let outcome = AssetDiscovery.scanOutcome(root: card)
        XCTAssertEqual(outcome.unrecognizedFiles, 0)
        XCTAssertTrue(outcome.isComplete)
    }

    /// HEIF is what every iPhone and every recent Canon/Sony in HEIF mode writes.
    /// It was dropped by the extension filter, silently.
    func testHeifIsAFirstClassPrimary() throws {
        let card = try freshTempDir("HeifScan")
        try write(Data(repeating: 0x44, count: 256), named: "IMG_0002.HEIC", in: card)
        try write(Data(repeating: 0x45, count: 256), named: "IMG_0003.hif", in: card)

        let outcome = AssetDiscovery.scanOutcome(root: card)
        XCTAssertEqual(outcome.bundles.count, 2)
        XCTAssertEqual(outcome.unrecognizedFiles, 0)
    }

    /// Video is a primary in its own bundle and takes its sidecars with it.
    func testVideoIsIngestedAsItsOwnBundleWithSidecars() throws {
        let card = try freshTempDir("VideoScan")
        try write(Data(repeating: 0x55, count: 512), named: "C0001.MP4", in: card)
        try write(Data("sidecar".utf8), named: "C0001.xmp", in: card)
        try write(Data(repeating: 0x56, count: 512), named: "CLIP.mov", in: card)

        let outcome = AssetDiscovery.scanOutcome(root: card)
        XCTAssertEqual(outcome.bundles.count, 2)
        let mp4 = outcome.bundles.first { $0.primary.url.lastPathComponent == "C0001.MP4" }
        XCTAssertEqual(mp4?.companions.count, 1)
        XCTAssertEqual(mp4?.companions.first?.kind, .xmp)
    }

    /// A clip beside a RAW of the same stem is its own shot, not the RAW's pair.
    /// Folding it in as a companion would make the two inseparable and hide the
    /// video inside a still's bundle.
    func testVideoIsNeverAbsorbedAsACompanionOfARaw() throws {
        let card = try freshTempDir("VideoNotCompanion")
        try write(Data(repeating: 0x61, count: 256), named: "IMG_0001.CR2", in: card)
        try write(Data(repeating: 0x62, count: 256), named: "IMG_0001.MOV", in: card)

        let outcome = AssetDiscovery.scanOutcome(root: card)
        XCTAssertEqual(outcome.bundles.count, 2)
        XCTAssertTrue(outcome.bundles.allSatisfy { $0.companions.isEmpty })
    }

    // MARK: - F4 · a destination that isn't there is refused

    /// The CLI has always refused a `--to` that doesn't exist, and the reason is
    /// on record: `FileCopier` creates intermediate directories, so a typo'd
    /// destination materializes a whole new library tree and exits 0 with a
    /// manifest attesting to it. The GUI had no equivalent check.
    func testAMissingDestinationIsRefused() throws {
        let dir = try freshTempDir("MissingDest")
        let real = dir.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let gone = dir.appendingPathComponent("Renamed In Finder", isDirectory: true)

        XCTAssertNil(PreflightCheck.missingDestinations(primary: real, archives: []))
        XCTAssertNotNil(PreflightCheck.missingDestinations(primary: gone, archives: []))
        XCTAssertNotNil(PreflightCheck.missingDestinations(primary: real, archives: [gone]),
                        "a mirror that isn't there is still a destination that isn't there")
    }

    /// A path that exists but is a file fails on every single copy; say so up
    /// front rather than once per photo.
    func testAFileWhereAFolderShouldBeIsRefused() throws {
        let dir = try freshTempDir("FileNotFolder")
        let notAFolder = try write(Data("hello".utf8), named: "Library", in: dir)
        let message = PreflightCheck.missingDestinations(primary: notAFolder, archives: [])
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("not a folder") == true)
    }

    // MARK: - F9 · timestamps survive the copy

    /// Every copied file wore the *ingest* time as its modification and creation
    /// date. Wrong on its own terms, and it destroyed the mtime `ExifReader`
    /// falls back to for anything without a parseable capture date — so
    /// re-ingesting an already-ingested folder filed it all under the copy date.
    func testCopyPreservesTheSourceModificationTime() throws {
        let dir = try freshTempDir("Timestamps")
        let source = try write(Data(repeating: 0x77, count: 4096), named: "IMG_0001.CR2", in: dir)
        let backThen = Date(timeIntervalSince1970: 1_400_000_000)   // 2014
        try FileManager.default.setAttributes([.modificationDate: backThen],
                                              ofItemAtPath: source.path)

        let destination = dir.appendingPathComponent("copy.CR2")
        _ = try FileCopier.copyAndHash(source: source, destination: destination) { _ in }

        let copied = try FileManager.default.attributesOfItem(atPath: destination.path)
        let copiedDate = try XCTUnwrap(copied[.modificationDate] as? Date)
        XCTAssertEqual(copiedDate.timeIntervalSince1970, backThen.timeIntervalSince1970, accuracy: 1,
                       "the library must record when the photo was taken, not when it was offloaded")
    }

    // MARK: - F5/F6 · verify reports what it could not use

    /// `partial` was written on every job and read by nothing. A cancelled
    /// 40-of-500 ingest wrote a correct `partial: true` manifest, and `verify`
    /// then printed `✓ All 40 files match` and exited 0 — forever.
    func testVerifyReportsManifestsMarkedPartial() throws {
        let library = try freshTempDir("PartialVerify")
        let photo = try write(Data(repeating: 0x31, count: 1024), named: "IMG_0001.CR2",
                              in: library.appendingPathComponent("2026/2026-05-28", isDirectory: true))
        let digest = try XxHash64.hash(fileAt: photo)

        try writeManifest(in: library, partial: true, entries: [
            ManifestEntry(name: "IMG_0001.CR2", path: "2026/2026-05-28/IMG_0001.CR2",
                          bytes: 1024, xxhash64: String(format: "%016llx", digest), status: "copied"),
        ])

        let report = try XCTUnwrap(VerifyEngine.run(target: library))
        XCTAssertEqual(report.verified, 1)
        XCTAssertTrue(report.allGood, "the 40 files that did land really are intact")
        XCTAssertEqual(report.partialManifests, 1, """
            …but the library is known to be missing photos the card held, and that \
            is the one thing a clean tick must not conceal.
            """)
    }

    /// Entries with no digest were dropped with `continue` and no tally, and
    /// `total` is `verified + issues.count` — so they were invisible. Manifests
    /// written before skipped-duplicate entries carried a digest still sit in
    /// real libraries with `xxhash64: nil` on every skipped file.
    func testVerifyCountsEntriesItCannotCheck() throws {
        let library = try freshTempDir("UndigestedVerify")
        let photo = try write(Data(repeating: 0x32, count: 512), named: "IMG_0001.CR2",
                              in: library.appendingPathComponent("2026/2026-05-28", isDirectory: true))
        let digest = try XxHash64.hash(fileAt: photo)

        try writeManifest(in: library, partial: false, entries: [
            ManifestEntry(name: "IMG_0001.CR2", path: "2026/2026-05-28/IMG_0001.CR2",
                          bytes: 512, xxhash64: String(format: "%016llx", digest), status: "copied"),
            ManifestEntry(name: "IMG_0002.CR2", path: "2026/2026-05-28/IMG_0002.CR2",
                          bytes: 512, xxhash64: nil, status: "skipped"),
            ManifestEntry(name: "IMG_0003.CR2", path: "2026/2026-05-28/IMG_0003.CR2",
                          bytes: 512, xxhash64: nil, status: "skipped"),
        ])

        let report = try XCTUnwrap(VerifyEngine.run(target: library))
        XCTAssertEqual(report.verified, 1)
        XCTAssertEqual(report.undigested, 2, "two entries were never checked and the report must say so")
    }

    /// Containment is what stops a `../../..` entry turning verify into an
    /// existence oracle. Dropping such entries is correct; dropping them
    /// *silently* lets a manifest that is half traversal attempts read as a clean
    /// pass over the half that wasn't.
    func testVerifyCountsEntriesThatEscapeTheLibraryRoot() throws {
        let library = try freshTempDir("EscapedVerify")
        let photo = try write(Data(repeating: 0x33, count: 512), named: "IMG_0001.CR2",
                              in: library.appendingPathComponent("2026/2026-05-28", isDirectory: true))
        let digest = try XxHash64.hash(fileAt: photo)

        try writeManifest(in: library, partial: false, entries: [
            ManifestEntry(name: "IMG_0001.CR2", path: "2026/2026-05-28/IMG_0001.CR2",
                          bytes: 512, xxhash64: String(format: "%016llx", digest), status: "copied"),
            ManifestEntry(name: "hosts", path: "../../../../../../etc/hosts",
                          bytes: 1, xxhash64: "0000000000000001", status: "copied"),
        ])

        let report = try XCTUnwrap(VerifyEngine.run(target: library))
        XCTAssertEqual(report.verified, 1)
        XCTAssertEqual(report.outOfRoot, 1)
    }

    // MARK: - Manifest fixture

    /// Writes a manifest into `PhotoDrop Manifests/` the way a job would, so the
    /// tests above exercise the real decode path rather than a hand-built `Plan`.
    private func writeManifest(in root: URL, partial: Bool, entries: [ManifestEntry]) throws {
        let folder = root.appendingPathComponent(ManifestWriter.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = Manifest(
            schema: Manifest.schemaID,
            app: Manifest.appName,
            createdAt: Date(),
            source: "CARD",
            primaryDestination: root.path(percentEncoded: false),
            archiveDestination: nil,
            destinations: [root.path(percentEncoded: false)],
            verified: true,
            partial: partial,
            filesCopied: entries.count,
            filesSkipped: 0,
            filesFailed: 0,
            totalBytes: entries.reduce(Int64(0)) { $0 + $1.bytes },
            elapsedSeconds: 1,
            files: entries
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("ingest-test.json"))
    }
}
