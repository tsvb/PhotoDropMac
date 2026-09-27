import XCTest
import Darwin
@testable import PhotoDropMac

/// A library the user did not make — shared, downloaded, handed over on a drive —
/// can carry symbolic links and special files as well as manifests, and three
/// readers of it trusted the filesystem where they had learned not to trust the
/// manifest.
///
/// **Threat model.** The attacker authors the library folder: its manifests, its
/// directory structure, its links, its FIFOs. The user is benign and runs
/// `verify`, `heal` (and reviews its script) or `sync` on it.
///
/// **Before-state, traced from the code** (no measurement was possible where
/// this was written; each test below fails, or trips its watchdog, against it):
///
/// - **Symlinks inside the library.** `ManifestWriter.resolve` is lexical, so
///   `<lib>/2024 -> ../../Library` made `2024/LaunchAgents/x.plist` a contained
///   entry. `heal` found "a healthy copy" in a gated mirror the same download
///   shipped and emitted `mkdir -p '<lib>/2024/LaunchAgents' && cp -p …` — every
///   path on screen inside the library, the write landing in `~/Library`.
///   `verify` hashed files outside the library under a library name.
/// - **Special files read by `sync`.** `FileCopier.copyAndHash` opened its source
///   with `FileHandle(forReadingFrom:)`: a FIFO entry blocked `open()` forever,
///   and a device streamed into the mirror until the disk filled.
/// - **Special files among the manifests.** Every `*.json` in
///   `PhotoDrop Manifests/` went through `Data(contentsOf:)`, so a FIFO named
///   `x.json` hung `verify`, `heal`, `sync` and the nightly agent.
/// - **Symlinks inside a destination.** The same library is also somewhere the
///   app *writes*. `FileCopier` made folders with
///   `createDirectory(withIntermediateDirectories:)` and the file with `open()`,
///   both of which follow links in every component but the last, so
///   `<lib>/2026 -> /Users/Shared/x` sent the user's photos outside the library
///   while the manifest recorded them as `2026/…`. A `PhotoDrop Manifests` link
///   did the same to the receipts.
final class UntrustedLibraryFileTests: XCTestCase {

    // MARK: - Symlinks inside the library (verify, heal)

    /// A folder inside the library that is a link to somewhere else.
    func testVerifyRefusesAnEntryReachedThroughASymlinkedFolder() throws {
        let base = try freshTempDir()
        let lib = try makeDir(base, "lib")
        let outside = try makeDir(base, "outside")
        let digest = try write("photo", to: outside.appendingPathComponent("x.CR2"))
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent("2024"),
                                                   withDestinationURL: outside)
        try writeManifest(in: lib, destinations: [lib], entries: [entry("2024/x.CR2", digest)])

        let report = try XCTUnwrap(VerifyEngine.run(target: lib))
        XCTAssertEqual(report.verified, 0, "a file outside the library was hashed under a library name")
        XCTAssertEqual(report.outOfRoot, 1, "the refusal must be reported, not silent")
    }

    /// `cp` follows a linked final component too, so the file itself is checked.
    func testVerifyRefusesAnEntryWhoseFileIsASymlink() throws {
        let base = try freshTempDir()
        let lib = try makeDir(base, "lib")
        let day = try makeDir(lib, "2024")
        let outside = try makeDir(base, "outside")
        let digest = try write("photo", to: outside.appendingPathComponent("y.CR2"))
        try FileManager.default.createSymbolicLink(at: day.appendingPathComponent("y.CR2"),
                                                   withDestinationURL: outside.appendingPathComponent("y.CR2"))
        try writeManifest(in: lib, destinations: [lib], entries: [entry("2024/y.CR2", digest)])

        let report = try XCTUnwrap(VerifyEngine.run(target: lib))
        XCTAssertEqual(report.verified, 0)
        XCTAssertEqual(report.outOfRoot, 1)
    }

    /// Only components *below* the root are examined: reaching the library itself
    /// through a link (an alias the user made, or `/tmp`) is the user's choice.
    func testALinkAboveTheLibraryRootIsNotRefused() throws {
        let base = try freshTempDir()
        let lib = try makeDir(base, "lib")
        let digest = try write("photo", to: try makeDir(lib, "2024").appendingPathComponent("x.CR2"))
        try writeManifest(in: lib, destinations: [lib], entries: [entry("2024/x.CR2", digest)])
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: lib)

        let report = try XCTUnwrap(VerifyEngine.run(target: alias))
        XCTAssertEqual(report.verified, 1)
        XCTAssertEqual(report.outOfRoot, 0)
    }

    /// The write side: the restore script must never target a path that leaves
    /// the library on disk, however contained its text looks.
    func testHealEmitsNoRestoreLineThroughASymlinkedFolder() throws {
        let base = try freshTempDir()
        let lib = try makeDir(base, "lib")
        let outside = try makeDir(base, "outside")
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent("2024"),
                                                   withDestinationURL: outside)
        // A mirror that passes the gate — it carries its own manifest folder —
        // holding the attacker's payload under the same relative path.
        let mirror = try makeDir(base, "mirror")
        _ = try makeDir(mirror, ManifestWriter.folderName)
        let payload = mirror.appendingPathComponent("2024/LaunchAgents/evil.plist")
        try FileManager.default.createDirectory(at: payload.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let digest = try write("payload", to: payload)
        try writeManifest(in: lib, destinations: [lib, mirror],
                          entries: [entry("2024/LaunchAgents/evil.plist", digest)])

        let report = try XCTUnwrap(HealEngine.run(target: lib))
        XCTAssertTrue(report.recoverable.isEmpty, "offered a restore that writes through a link: \(report.candidates)")
        XCTAssertEqual(report.outOfRoot, 1, "the refused entry must be reported")
        XCTAssertFalse(HealEngine.restoreScript(report).contains("cp -p"),
                       "the script must carry no copy for a path that leaves the library")
    }

    /// The read side of the same rule: a mirror copy reached through a link inside
    /// the mirror is not offered as a restore source.
    func testHealDoesNotOfferAMirrorCopyReachedThroughASymlink() throws {
        let base = try freshTempDir()
        let lib = try makeDir(base, "lib")
        _ = try makeDir(lib, "2024")                                  // the file itself is missing
        let elsewhere = try makeDir(base, "elsewhere")
        let digest = try write("photo", to: elsewhere.appendingPathComponent("x.CR2"))
        let mirror = try makeDir(base, "mirror")
        _ = try makeDir(mirror, ManifestWriter.folderName)
        try FileManager.default.createSymbolicLink(at: mirror.appendingPathComponent("2024"),
                                                   withDestinationURL: elsewhere)
        try writeManifest(in: lib, destinations: [lib, mirror], entries: [entry("2024/x.CR2", digest)])

        let report = try XCTUnwrap(HealEngine.run(target: lib))
        XCTAssertEqual(report.candidates.map(\.relPath), ["2024/x.CR2"])
        XCTAssertNil(report.candidates.first?.recoverableFrom,
                     "a mirror copy reached through a link was offered as a restore source")
    }

    // MARK: - Special files read as photos (copy, sync)

    /// The primitive: a FIFO source is refused, and refusing it cannot block.
    func testCopyRefusesAFIFOSourceWithoutBlocking() throws {
        let dir = try freshTempDir()
        let fifo = dir.appendingPathComponent("IMG_0001.CR2")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0, "could not create the fixture FIFO")
        let destination = dir.appendingPathComponent("out/IMG_0001.CR2")

        let threw = runWithWatchdog(seconds: 10) { () -> Bool in
            do {
                _ = try FileCopier.copyAndHash(source: fifo, destination: destination) { _ in }
                return false
            } catch {
                return true
            }
        }
        XCTAssertEqual(threw, true, "a FIFO source must be refused, not read")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a refused source must leave nothing at the destination")
    }

    /// A character device is never a photo. `/dev/null` is the harmless member of
    /// the class — it returns EOF — so a regression "succeeds" here with an empty
    /// file rather than filling the disk the way `/dev/zero` would.
    func testCopyRefusesADeviceSource() throws {
        let dir = try freshTempDir()
        let destination = dir.appendingPathComponent("IMG_0001.CR2")
        XCTAssertThrowsError(try FileCopier.copyAndHash(source: URL(fileURLWithPath: "/dev/null"),
                                                        destination: destination) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// End to end: `sync` over a library whose manifest names a FIFO copies what it
    /// can, reports the rest, and returns.
    func testSyncDoesNotHangOnAFIFOInTheLibrary() throws {
        let base = try freshTempDir()
        let lib = try makeDir(base, "lib")
        let day = try makeDir(lib, "2024")
        let digest = try write("photo", to: day.appendingPathComponent("a.CR2"))
        XCTAssertEqual(mkfifo(day.appendingPathComponent("b.CR2").path, 0o600), 0)
        try writeManifest(in: lib, destinations: [lib], entries: [
            entry("2024/a.CR2", digest),
            entry("2024/b.CR2", digest),
        ])
        let mirror = try makeDir(base, "mirror")

        let outcome = runWithWatchdog(seconds: 20) { () -> SyncEngine.Outcome? in
            try? SyncEngine.run(library: lib, mirror: mirror)
        }
        guard let result = outcome ?? nil else { return XCTFail("sync hung on a FIFO entry, or refused the library") }
        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.failed.map { $0.path }, ["2024/b.CR2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("2024/b.CR2").path))
    }

    // MARK: - Special files among the manifests

    /// A FIFO in `PhotoDrop Manifests/` named like a manifest is skipped, and the
    /// real manifests beside it still count.
    func testAFIFOManifestDoesNotHangVerify() throws {
        let lib = try freshTempDir()
        let digest = try write("photo", to: try makeDir(lib, "2024").appendingPathComponent("x.CR2"))
        try writeManifest(in: lib, destinations: [lib], entries: [entry("2024/x.CR2", digest)])
        let trap = lib.appendingPathComponent(ManifestWriter.folderName).appendingPathComponent("trap.json")
        XCTAssertEqual(mkfifo(trap.path, 0o600), 0)

        let outcome = runWithWatchdog(seconds: 10) { VerifyEngine.run(target: lib) }
        guard let report = outcome ?? nil else { return XCTFail("verify hung on a FIFO named like a manifest") }
        XCTAssertEqual(report.manifestCount, 1)
        XCTAssertEqual(report.verified, 1)
    }

    /// The reader's own bounds: devices are refused, and so is anything over the cap.
    func testRegularFileReaderRefusesDevicesAndOversizedFiles() throws {
        XCTAssertThrowsError(try RegularFile.contents(of: URL(fileURLWithPath: "/dev/null"), maxBytes: 1 << 20))
        XCTAssertNil(ManifestWriter.readManifest(at: URL(fileURLWithPath: "/dev/null")))

        let file = try freshTempDir().appendingPathComponent("m.json")
        try Data("12345".utf8).write(to: file)
        XCTAssertThrowsError(try RegularFile.contents(of: file, maxBytes: 4))
        XCTAssertEqual(try RegularFile.contents(of: file, maxBytes: 5), Data("12345".utf8))
    }

    // MARK: - Symlinks inside a destination (ingest and sync writes)

    /// A folder below the root that is a link: nothing may land where it points.
    func testCopyRefusesToWriteThroughASymlinkedFolderBelowTheRoot() throws {
        let base = try freshTempDir()
        let lib = try makeDir(base, "lib")
        let outside = try makeDir(base, "outside")
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent("2026"),
                                                   withDestinationURL: outside)
        let source = base.appendingPathComponent("IMG_0001.CR2")
        try Data("photo".utf8).write(to: source)
        let destination = lib.appendingPathComponent("2026/2026-05-28/IMG_0001.CR2")

        XCTAssertThrowsError(try FileCopier.copyAndHash(source: source, destination: destination,
                                                        destinationRoot: lib) { _ in }) { error in
            guard let copyError = error as? FileCopierError,
                  case .destinationThroughSymlink = copyError else {
                return XCTFail("expected a refusal naming the link, got \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [],
                       "nothing may land outside the library — not a folder, not a file")
    }

    /// The root itself may be reached through a link — an alias the user made, or
    /// `/tmp` — and the folders below it are still created as before.
    func testCopyWritesWhenOnlyTheRootIsReachedThroughALink() throws {
        let base = try freshTempDir()
        let lib = try makeDir(base, "lib")
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: lib)
        let source = base.appendingPathComponent("IMG_0001.CR2")
        try Data("photo".utf8).write(to: source)

        _ = try FileCopier.copyAndHash(source: source,
                                       destination: alias.appendingPathComponent("2026/2026-05-28/IMG_0001.CR2"),
                                       destinationRoot: alias) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: lib.appendingPathComponent("2026/2026-05-28/IMG_0001.CR2").path))
    }

    /// The receipt is not written through a linked `PhotoDrop Manifests` either;
    /// the failure is returned, where it gates the eject.
    func testManifestIsNotWrittenThroughASymlinkedManifestFolder() throws {
        let base = try freshTempDir()
        let lib = try makeDir(base, "lib")
        let outside = try makeDir(base, "outside")
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent(ManifestWriter.folderName),
                                                   withDestinationURL: outside)
        let manifest = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName, createdAt: Date(), source: nil,
            primaryDestination: lib.path(percentEncoded: false), archiveDestination: nil,
            destinations: [lib.path(percentEncoded: false)], verified: true, partial: false,
            filesCopied: 0, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: [])

        XCTAssertNil(ManifestWriter.write(manifest, intoRoot: lib, stamp: Date()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    // MARK: - Helpers

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropUntrustedLibrary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeDir(_ parent: URL, _ name: String) throws -> URL {
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `content` to `url` and returns its digest as a manifest records it.
    private func write(_ content: String, to url: URL) throws -> String {
        try Data(content.utf8).write(to: url)
        return String(format: "%016llx", try XxHash64.hash(fileAt: url))
    }

    private func entry(_ path: String, _ digest: String) -> ManifestEntry {
        ManifestEntry(name: (path as NSString).lastPathComponent, path: path,
                      bytes: 5, xxhash64: digest, status: "verified")
    }

    private func writeManifest(in root: URL, destinations: [URL], entries: [ManifestEntry]) throws {
        let manifest = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName,
            createdAt: Date(timeIntervalSince1970: 1_716_000_000), source: nil,
            primaryDestination: root.path(percentEncoded: false),
            archiveDestination: nil,
            destinations: destinations.map { $0.path(percentEncoded: false) },
            verified: true, partial: false,
            filesCopied: entries.count, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: entries)
        let folder = root.appendingPathComponent(ManifestWriter.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("ingest-test.json"))
    }

    /// Runs `body` on a background queue and fails the test if it does not return
    /// in time. A timeout **fails**; a hang is the defect under test, and a skip
    /// would print `** TEST SUCCEEDED **` over it.
    private func runWithWatchdog<T>(seconds: Double, _ body: @escaping @Sendable () -> T) -> T? {
        let box = WatchdogBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = body()
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else {
            XCTFail("timed out after \(seconds)s")
            return nil
        }
        return box.value
    }

    private final class WatchdogBox<T>: @unchecked Sendable {
        var value: T?
    }
}
