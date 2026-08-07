import XCTest
@testable import PhotoDropMac

/// The failure paths of a multi-destination ingest — the branches nothing
/// exercised before, and where every one of these regressions was found.
///
/// Each test below reproduces a measured defect:
///  * a failing mirror starved every mirror after it and voided the primary's success
///  * one folder used as both primary and archive reported a clean job as a total failure
///  * cancelling wrote no manifest, leaving copied files with no integrity record
///  * `verifiedBundles` counted bundles that were never hash-checked
final class IngestEngineFailureTests: XCTestCase {

    // MARK: - Fixtures

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IngestEngineFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            // Restore permissions so cleanup can recurse into the chmod'd mirror.
            if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
                for case let u as URL in e {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
                }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func captureDate() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 28; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    private func makeBundle(_ name: String, bytes: Int, byte: UInt8 = 0x42, in tmp: URL) throws -> AssetBundle {
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let url = card.appendingPathComponent(name)
        try Data(repeating: byte, count: bytes).write(to: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let photo = ScannedPhoto(id: url, url: url, size: Int64(size),
                                 dateTaken: captureDate(), dateSource: .fileModification)
        return AssetBundle(primary: photo, companions: [])
    }

    private func dir(_ name: String, in tmp: URL) throws -> URL {
        let url = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Collects the engine's callbacks. The engine invokes them serially from
    /// its own task, so plain mutation is safe here.
    private final class Sink: @unchecked Sendable {
        var progress: [CopyProgress] = []
        var logs: [LogEntry] = []
        var errors: [String] { logs.filter { $0.kind == .error }.map(\.line) }
    }

    private final class CancelFlag: @unchecked Sendable { var value = false }

    @discardableResult
    private func ingest(_ bundles: [AssetBundle], primary: URL, archives: [URL] = [],
                        tmp: URL, verify: Bool = true,
                        cancelAfterBundles: Int? = nil,
                        sink: Sink = Sink()) async -> (CopyResult, Sink) {
        let flag = CancelFlag()
        let engine = IngestEngine(
            bundles: bundles, description: "", primaryRoot: primary, archiveRoots: archives,
            verify: verify, ejectAfter: false, sourceMountPoint: nil, sourceVolumeID: "test-vol",
            template: .default, cardLabel: "",
            cache: HashCache(storeURL: tmp.appendingPathComponent("cache-\(UUID()).json")),
            indexStoreURL: tmp.appendingPathComponent("index-\(UUID()).json"),
            isCancelled: { flag.value },
            onProgress: { p in
                sink.progress.append(p)
                if let n = cancelAfterBundles, p.completedBundles >= n { flag.value = true }
            },
            onLog: { sink.logs.append($0) })
        return (await engine.run(), sink)
    }

    private func photoNames(in root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let u as URL in e where !u.path.contains(ManifestWriter.folderName) {
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(u.lastPathComponent)
            }
        }
        return out.sorted()
    }

    private func manifests(in root: URL) -> [URL] {
        let folder = root.appendingPathComponent(ManifestWriter.folderName, isDirectory: true)
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "json" }
    }

    // MARK: - A failing mirror is a failing mirror, not a failing job

    /// Regression: the per-bundle copy loop used to wrap *all* destinations in
    /// one `do`, so a throw at mirror 1 skipped mirror 2 entirely and counted the
    /// bundle failed even though the primary had already landed and verified.
    /// Measured before the fix: healthy third destination received 0 files.
    func testFailingMirrorDoesNotStarveTheNextMirror() async throws {
        let tmp = try freshTempDir()
        let primary = try dir("primary", in: tmp)
        let badMirror = try dir("bad", in: tmp)
        let goodMirror = try dir("good", in: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: badMirror.path)

        let bundles = try (1...3).map { try makeBundle("IMG_000\($0).JPG", bytes: 4096, byte: UInt8($0), in: tmp) }
        let (result, _) = await ingest(bundles, primary: primary,
                                       archives: [badMirror, goodMirror], tmp: tmp)

        XCTAssertEqual(photoNames(in: primary).count, 3, "the primary must be complete")
        XCTAssertEqual(photoNames(in: goodMirror).count, 3,
                       "a healthy mirror must still be written when an earlier one fails")
        XCTAssertEqual(result.primaryFailures, 0, "the library is not what failed")
        XCTAssertEqual(result.failedMirrors, [badMirror.path(percentEncoded: false)],
                       "the failure is attributed to the mirror that caused it")
        XCTAssertEqual(result.failuresByDestination[badMirror.path(percentEncoded: false)], 3)
    }

    func testPrimaryFailureIsStillReportedAgainstThePrimary() async throws {
        let tmp = try freshTempDir()
        let primary = try dir("primary", in: tmp)
        let mirror = try dir("mirror", in: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: primary.path)

        let bundles = [try makeBundle("IMG_0001.JPG", bytes: 4096, in: tmp)]
        let (result, _) = await ingest(bundles, primary: primary, archives: [mirror], tmp: tmp)

        XCTAssertEqual(result.primaryFailures, 1)
        XCTAssertEqual(photoNames(in: mirror).count, 1,
                       "the mirror is still attempted — a broken primary must not cost the backup too")
    }

    // MARK: - One folder is never written twice

    /// Regression: `archive == primary` made pass 2 collide with pass 1's own
    /// file. `O_EXCL` refused (correctly), the bundle was counted failed, and a
    /// completely successful ingest reported every bundle failed. Deduped at the
    /// engine now, so no caller can reintroduce it.
    func testDuplicateDestinationIsIgnoredRatherThanCollidingWithItself() async throws {
        let tmp = try freshTempDir()
        let primary = try dir("lib", in: tmp)

        let bundles = try (1...3).map { try makeBundle("IMG_10\($0).JPG", bytes: 4096, byte: UInt8($0), in: tmp) }
        let (result, sink) = await ingest(bundles, primary: primary, archives: [primary], tmp: tmp)

        XCTAssertEqual(photoNames(in: primary).count, 3)
        XCTAssertEqual(result.filesFailed, 0, "a successful ingest must not report failures")
        XCTAssertEqual(result.primaryFailures, 0)
        XCTAssertTrue(result.failedMirrors.isEmpty)
        XCTAssertTrue(sink.errors.isEmpty, "no 'refused to overwrite' noise: \(sink.errors)")
    }

    func testTrailingSlashSpellingOfPrimaryIsAlsoIgnored() async throws {
        let tmp = try freshTempDir()
        let primary = try dir("lib", in: tmp)
        let sameFolderOtherSpelling = URL(fileURLWithPath: primary.path + "/", isDirectory: true)

        let bundles = [try makeBundle("IMG_2001.JPG", bytes: 4096, in: tmp)]
        let (result, _) = await ingest(bundles, primary: primary,
                                       archives: [sameFolderOtherSpelling], tmp: tmp)

        XCTAssertEqual(result.filesFailed, 0)
        XCTAssertEqual(photoNames(in: primary).count, 1)
    }

    // MARK: - Cancelling keeps the receipt

    /// Regression: cancellation returned before the manifest was written, so the
    /// bundles already on disk (which are *not* rolled back) had no integrity
    /// record at all — and re-ingesting them dedup-skips without a digest, so
    /// `verify` would report success over zero files forever.
    func testCancellationStillWritesAManifestForWhatLanded() async throws {
        let tmp = try freshTempDir()
        let primary = try dir("lib", in: tmp)

        let bundles = try (1...8).map {
            try makeBundle("IMG_30\(String(format: "%02d", $0)).JPG", bytes: 8192, byte: UInt8($0), in: tmp)
        }
        let (result, _) = await ingest(bundles, primary: primary, tmp: tmp, cancelAfterBundles: 3)

        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.halted, "cancelling is not a halt")
        let landed = photoNames(in: primary).count
        XCTAssertGreaterThan(landed, 0)
        XCTAssertLessThan(landed, 8, "the run really did stop early")

        let manifestURL = try XCTUnwrap(result.manifestURL, "a cancelled run must still write its manifest")
        XCTAssertEqual(manifests(in: primary).count, 1)
        XCTAssertNotNil(result.logURL, "…and its log")

        let manifest = try XCTUnwrap(ManifestWriter.decode(try Data(contentsOf: manifestURL)))
        XCTAssertEqual(manifest.partial, true, "the manifest says the card was not fully ingested")
        XCTAssertEqual(manifest.files.count, landed,
                       "every file on disk is accounted for, and no file that isn't")

        // The whole point: what landed can be verified afterwards.
        let report = try XCTUnwrap(VerifyEngine.run(target: primary))
        XCTAssertEqual(report.verified, landed)
        XCTAssertTrue(report.allGood)
    }

    func testCancellationDoesNotEjectTheCard() async throws {
        let tmp = try freshTempDir()
        let primary = try dir("lib", in: tmp)
        let bundles = try (1...6).map { try makeBundle("IMG_40\($0).JPG", bytes: 4096, byte: UInt8($0), in: tmp) }
        let (result, _) = await ingest(bundles, primary: primary, tmp: tmp, cancelAfterBundles: 2)
        XCTAssertFalse(result.wasEjected, "a half-ingested card must stay mounted")
    }

    // MARK: - "Verified" means verified

    /// Regression: `verifiedBundles` incremented unconditionally, and the
    /// cancelled/failed UI renders it as "already-verified … safe on disk" —
    /// vouching for bytes nothing had read back.
    func testVerifiedCountIsZeroWhenVerificationIsOff() async throws {
        let tmp = try freshTempDir()
        let primary = try dir("lib", in: tmp)

        let bundles = try (1...3).map { try makeBundle("IMG_50\($0).JPG", bytes: 4096, byte: UInt8($0), in: tmp) }
        let (_, sink) = await ingest(bundles, primary: primary, tmp: tmp, verify: false)

        XCTAssertEqual(sink.logs.filter { $0.kind == .verified }.count, 0, "nothing was hash-checked")
        XCTAssertEqual(sink.progress.last?.verifiedBundles, 0,
                       "so nothing may be reported as verified")
        XCTAssertEqual(sink.progress.last?.completedBundles, 3,
                       "the honest count is still available to the UI")
    }

    func testVerifiedCountTracksBundlesWhenVerificationIsOn() async throws {
        let tmp = try freshTempDir()
        let primary = try dir("lib", in: tmp)

        let bundles = try (1...3).map { try makeBundle("IMG_60\($0).JPG", bytes: 4096, byte: UInt8($0), in: tmp) }
        let (_, sink) = await ingest(bundles, primary: primary, tmp: tmp, verify: true)

        XCTAssertEqual(sink.progress.last?.verifiedBundles, 3)
    }

    /// A bundle whose *primary* copy failed was never verified there, whatever
    /// the mirrors did.
    func testVerifiedCountExcludesBundlesWhosePrimaryFailed() async throws {
        let tmp = try freshTempDir()
        let primary = try dir("primary", in: tmp)
        let mirror = try dir("mirror", in: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: primary.path)

        let bundles = [try makeBundle("IMG_7001.JPG", bytes: 4096, in: tmp)]
        let (_, sink) = await ingest(bundles, primary: primary, archives: [mirror], tmp: tmp, verify: true)

        XCTAssertEqual(sink.progress.last?.verifiedBundles, 0)
    }
}
