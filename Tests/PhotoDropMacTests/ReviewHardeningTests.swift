import XCTest
import Darwin
@testable import PhotoDropMac

/// The Low-severity findings of the security review, one test each where the
/// behavior is reachable from the suite.
///
/// **Threat model.** As everywhere in this app: the card, and any library the
/// user did not make, are attacker-authored; the user, their hook and their
/// settings are not. Most of these are "a safety rule existed and one path did
/// not apply it".
///
/// **Before-state, traced from the code** (none of these was measured where the
/// fix was written; each test fails against the code before it):
///
/// - The app ran the post-ingest hook after a job that lost files to a full disk
///   or a failed manifest write; the CLI already refused. (`PostIngestHook.shouldRun`)
/// - `AssetDiscovery` used `.skipsHiddenFiles`, which skipped *flagged*-hidden
///   folders as well as dotfiles and counted neither, so a DCIM hidden by USB
///   malware read as a complete scan and the card could eject.
/// - `ChildProcess.run` waited for EOF on both pipes, and a grandchild the child
///   left running (`nohup rsync … &`) holds those pipes open: `run` never
///   returned, and the timeout signalled only the child that had already exited.
/// - `SafeText` missed the scalars that render as nothing — the tag block, the
///   soft hyphen, the Hangul fillers — which let two paths in a restore script
///   look identical.
/// - Sizes off the card were summed with `+`, which traps: two ~2^62-byte sparse
///   files crashed the app while it was still planning.
/// - `DestinationTopology.contains` compared components case-sensitively, so a
///   mirror inside the library went undetected when the two were typed in
///   different case on a case-insensitive volume.
/// - `VerifyEngine.build` accepted entries inside `PhotoDrop Manifests/`, so
///   `sync` copied an attacker's JSON into the mirror's own record folder.
/// - `FileCopier.copyAndHash` followed a link at the source's final component:
///   a card file swapped for `-> ~/.ssh/id_ed25519` after the scan was copied in.
final class ReviewHardeningTests: XCTestCase {

    // MARK: - The hook's gate

    func testHookRunsOnlyWhenTheLibraryIsWholeAndHasItsReceipt() {
        XCTAssertTrue(PostIngestHook.shouldRun(after: result()))
        XCTAssertFalse(PostIngestHook.shouldRun(after: result(primaryFailures: 3)),
                       "a job that lost files must not run the \"card is done\" hook")
        XCTAssertFalse(PostIngestHook.shouldRun(after: result(manifestFailures: ["/lib"])),
                       "no receipt, no hook")
        XCTAssertFalse(PostIngestHook.shouldRun(after: result(halted: true)))
        XCTAssertFalse(PostIngestHook.shouldRun(after: result(cancelled: true)))
    }

    // MARK: - Hidden files on the card

    func testFlaggedHiddenMediaIsCountedAsLeftBehind() throws {
        let card = try freshTempDir()
        let visible = try makeDir(card, "DCIM/100CANON")
        try Data("jpeg".utf8).write(to: visible.appendingPathComponent("IMG_0001.JPG"))

        // A folder hidden the way Windows malware hides DCIM: flagged, not dot-named.
        let hidden = try makeDir(card, "HIDDEN")
        try Data("jpeg".utf8).write(to: hidden.appendingPathComponent("IMG_0002.JPG"))
        try Data("guid".utf8).write(to: hidden.appendingPathComponent("IndexerVolumeGuid"))
        XCTAssertEqual(chflags(hidden.path, UInt32(UF_HIDDEN)), 0, "could not flag the fixture hidden")

        // Dot-named bookkeeping stays out of the count, as before.
        let trash = try makeDir(card, ".Trashes")
        try Data("jpeg".utf8).write(to: trash.appendingPathComponent("IMG_0003.JPG"))

        let outcome = AssetDiscovery.scanOutcome(root: card)
        XCTAssertEqual(outcome.bundles.map { $0.primary.url.lastPathComponent }, ["IMG_0001.JPG"],
                       "hidden media is reported, not ingested")
        XCTAssertEqual(outcome.unrecognizedFiles, 1,
                       "the hidden photo is left behind and must be counted — and only it")
        XCTAssertFalse(outcome.isComplete, "a card still holding a photo is not finished")
    }

    // MARK: - Child processes

    /// A grandchild holding the pipes must not keep `run` from returning.
    func testRunReturnsWhenABackgroundedGrandchildHoldsThePipes() async throws {
        let start = Date()
        let output = try await ChildProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & echo started"],
            timeout: 60, drainGrace: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15,
                          "run waited on a pipe held open by the grandchild")
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(String(decoding: output.stdout, as: UTF8.self).contains("started"),
                      "what was read before the grace ran out is still returned")
    }

    // MARK: - Invisible scalars

    func testScalarsThatRenderAsNothingAreFlagged() {
        for hostile in ["IMG\u{E0041}.CR2", "IMG\u{00AD}.CR2", "IMG\u{3164}.CR2", "IMG\u{FFF9}.CR2"] {
            XCTAssertTrue(SafeText.containsDangerousControls(hostile), "not flagged: \(hostile.unicodeScalars.map(\.value))")
        }
        // An emoji with its presentation selector is an honest filename.
        XCTAssertFalse(SafeText.containsDangerousControls("Party \u{2764}\u{FE0F}.JPG"))
    }

    // MARK: - Sizes off the card

    func testSizesSaturateInsteadOfTrapping() {
        let url = URL(fileURLWithPath: "/card/IMG_0001.CR2")
        let bundle = AssetBundle(
            primary: ScannedPhoto(id: url, url: url, size: Int64.max - 1,
                                  dateTaken: Date(), dateSource: .fileModification),
            companions: [CompanionFile(url: URL(fileURLWithPath: "/card/IMG_0001.xmp"), size: 1 << 62, kind: .xmp)])
        XCTAssertEqual(bundle.totalSize, Int64.max)
        XCTAssertEqual(Int64.max.saturatingMultiplied(by: 3), Int64.max)
        XCTAssertEqual(Int64(40).saturatingAdding(2), 42, "ordinary sums are unchanged")
    }

    // MARK: - Nested destinations

    func testNestingIsDetectedAcrossCase() {
        XCTAssertTrue(DestinationTopology.contains(URL(fileURLWithPath: "/NoSuchVolume/Pictures/Lib"),
                                                   URL(fileURLWithPath: "/nosuchvolume/pictures/lib/Backup")))
        XCTAssertFalse(DestinationTopology.contains(URL(fileURLWithPath: "/NoSuchVolume/Lib"),
                                                    URL(fileURLWithPath: "/NoSuchVolume/Lib2")),
                       "components, never string prefixes")
    }

    // MARK: - The record folder is not library content

    func testEntriesInsideTheManifestFolderAreRefused() throws {
        let lib = try freshTempDir()
        let day = try makeDir(lib, "2026/2026-05-28")
        let photo = day.appendingPathComponent("IMG_0001.CR2")
        try Data("photo".utf8).write(to: photo)
        let folder = try makeDir(lib, ManifestWriter.folderName)
        let planted = folder.appendingPathComponent("evil.json")
        try Data("{}".utf8).write(to: planted)
        try writeManifest(in: lib, entries: [
            entry("2026/2026-05-28/IMG_0001.CR2", try XxHash64.hash(fileAt: photo)),
            entry("\(ManifestWriter.folderName)/evil.json", try XxHash64.hash(fileAt: planted)),
        ])

        let report = try XCTUnwrap(VerifyEngine.run(target: lib))
        XCTAssertEqual(report.verified, 1)
        XCTAssertEqual(report.outOfRoot, 1, "the record folder is not content, and the refusal is reported")

        let mirror = try makeDir(try freshTempDir(), "mirror")
        _ = try SyncEngine.run(library: lib, mirror: mirror)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: mirror.appendingPathComponent("\(ManifestWriter.folderName)/evil.json").path),
            "sync planted the library's JSON in the mirror's own record folder")
    }

    // MARK: - The copy source

    func testCopyRefusesASourceThatIsALink() throws {
        let dir = try freshTempDir()
        let secret = dir.appendingPathComponent("id_ed25519")
        try Data("secret".utf8).write(to: secret)
        let source = dir.appendingPathComponent("IMG_0001.CR2")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: secret)
        let destination = dir.appendingPathComponent("out/IMG_0001.CR2")

        XCTAssertThrowsError(try FileCopier.copyAndHash(source: source, destination: destination) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Helpers

    private func result(primaryFailures: Int = 0, manifestFailures: [String] = [],
                        halted: Bool = false, cancelled: Bool = false) -> CopyResult {
        let primary = URL(fileURLWithPath: "/lib", isDirectory: true)
        return CopyResult(bundleCount: 1, filesCopied: 1, filesSkipped: 0, filesFailed: primaryFailures,
                          failuresByDestination: primaryFailures > 0
                              ? [primary.path(percentEncoded: false): primaryFailures] : [:],
                          failedFiles: [], duplicatesFoundElsewhere: [], landedFolders: [],
                          totalBytes: 0, elapsedSeconds: 1, primaryDestination: primary,
                          logURL: nil, manifestURL: nil, manifestFailures: manifestFailures,
                          wasEjected: false, halted: halted,
                          haltReason: halted ? "verification mismatch" : nil, cancelled: cancelled)
    }

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropReviewHardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            // The hidden flag does not stop removal, but clear it anyway so a
            // failed run leaves nothing odd behind in the temp folder.
            _ = chflags(dir.appendingPathComponent("HIDDEN").path, 0)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func makeDir(_ parent: URL, _ path: String) throws -> URL {
        let dir = parent.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func entry(_ path: String, _ digest: UInt64) -> ManifestEntry {
        ManifestEntry(name: (path as NSString).lastPathComponent, path: path, bytes: 0,
                      xxhash64: String(format: "%016llx", digest), status: "verified")
    }

    private func writeManifest(in root: URL, entries: [ManifestEntry]) throws {
        let manifest = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName,
            createdAt: Date(timeIntervalSince1970: 1_716_000_000), source: nil,
            primaryDestination: root.path(percentEncoded: false), archiveDestination: nil,
            destinations: [root.path(percentEncoded: false)], verified: true, partial: false,
            filesCopied: entries.count, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: entries)
        let folder = root.appendingPathComponent(ManifestWriter.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("ingest-test.json"))
    }
}
