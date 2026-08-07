import XCTest
@testable import PhotoDropMac

/// Every destination carries its own integrity record.
///
/// **Threat model.** A mirror exists so that when the library dies there is
/// another copy. That promise is only worth what can be checked, and nothing
/// could check a mirror: the manifest was written into the primary root only, so
/// `verify <mirror>` exited 2 "no manifest found", and `verify --xattr` — the one
/// remaining route — enumerates the files that *are* present and therefore cannot
/// detect absence at all (and no-ops entirely on exFAT/SMB, where `setxattr`
/// fails and the stamp silently did nothing).
///
/// **Measured before-state.** A 3-destination job whose NAS dropped offline at
/// bundle 40 of 500 wrote one manifest recording `partial: false`,
/// `destinations: [lib, nas, ssd]` and 500 entries all `verified`, because
/// `partial` consulted only cancel/halt and per-file state was recorded for the
/// primary alone. Every later `verify` and `heal` agreed with it, forever.
final class MirrorManifestTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
                for case let u as URL in e {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
                }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func dir(_ name: String, in tmp: URL) throws -> URL {
        let url = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBundle(_ name: String, byte: UInt8, in tmp: URL) throws -> AssetBundle {
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let url = card.appendingPathComponent(name)
        try Data(repeating: byte, count: 4096).write(to: url)
        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 28; c.hour = 12
        let photo = ScannedPhoto(id: url, url: url, size: 4096,
                                 dateTaken: Calendar.current.date(from: c)!,
                                 dateSource: .fileModification)
        return AssetBundle(primary: photo, companions: [])
    }

    private final class CancelFlag: @unchecked Sendable { var value = false }

    @discardableResult
    private func ingest(_ bundles: [AssetBundle], primary: URL, archives: [URL] = [],
                        tmp: URL, cancelAfterBundles: Int? = nil) async -> CopyResult {
        let flag = CancelFlag()
        let engine = IngestEngine(
            bundles: bundles, description: "", primaryRoot: primary, archiveRoots: archives,
            verify: true, ejectAfter: false, sourceMountPoint: nil, sourceVolumeID: "test-vol",
            template: .default, cardLabel: "",
            cache: HashCache(storeURL: tmp.appendingPathComponent("cache-\(UUID()).json")),
            indexStoreURL: tmp.appendingPathComponent("index-\(UUID()).json"),
            logDirectory: tmp.appendingPathComponent("Logs", isDirectory: true),
            isCancelled: { flag.value },
            onProgress: { p in
                if let n = cancelAfterBundles, p.completedBundles >= n { flag.value = true }
            })
        return await engine.run()
    }

    private func manifest(in root: URL) throws -> Manifest {
        let folder = root.appendingPathComponent(ManifestWriter.folderName, isDirectory: true)
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let json = try XCTUnwrap(all.first { $0.pathExtension == "json" },
                                 "no manifest under \(root.lastPathComponent)")
        return try XCTUnwrap(ManifestWriter.decode(try Data(contentsOf: json)))
    }

    // MARK: -

    /// The mirror is verifiable at all: it has a manifest of its own, listing
    /// what landed *there*, and `VerifyEngine` reports on it.
    func testEveryDestinationGetsItsOwnManifest() async throws {
        let tmp = try freshTempDir()
        let library = try dir("lib", in: tmp)
        let mirror = try dir("nas", in: tmp)
        let bundles = try (1...3).map { try makeBundle("IMG_000\($0).JPG", byte: UInt8($0), in: tmp) }

        _ = await ingest(bundles, primary: library, archives: [mirror], tmp: tmp)

        for root in [library, mirror] {
            let m = try manifest(in: root)
            XCTAssertEqual(m.files.count, 3, "\(root.lastPathComponent) must record its own three files")
            XCTAssertEqual(m.partial, false)
            XCTAssertEqual(m.primaryDestination, root.path(percentEncoded: false),
                           "each manifest describes the root it sits in, so heal treats it as the library")
            XCTAssertEqual(Set(m.destinations ?? []).count, 2, "both roots stay recorded as recovery sources")
        }

        let report = try XCTUnwrap(VerifyEngine.run(target: mirror))
        XCTAssertEqual(report.verified, 3, "verify <mirror> used to exit 2 'no manifest found'")
        XCTAssertTrue(report.allGood)
    }

    /// A mirror that could not be written says so, in its own record and in the
    /// primary's — instead of the primary asserting all three roots are complete.
    func testAShortMirrorIsRecordedAsPartial() async throws {
        let tmp = try freshTempDir()
        let library = try dir("lib", in: tmp)
        let badMirror = try dir("nas", in: tmp)
        let bundles = try (1...3).map { try makeBundle("IMG_000\($0).JPG", byte: UInt8($0), in: tmp) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: badMirror.path)

        let result = await ingest(bundles, primary: library, archives: [badMirror], tmp: tmp)

        XCTAssertEqual(result.primaryFailures, 0, "the library itself is fine")
        XCTAssertEqual(result.failedMirrors.count, 1)

        let primaryManifest = try manifest(in: library)
        XCTAssertEqual(primaryManifest.partial, false, "the primary really is complete")
        XCTAssertEqual(primaryManifest.files.count, 3)
        XCTAssertEqual(primaryManifest.filesFailed, 0,
                       "a root's manifest counts that root's failures, not the job's")

        // The mirror is unwritable, so it has no manifest folder at all — which is
        // itself the honest answer, and is what `verify <mirror>` now reports.
        let mirrorManifests = (try? FileManager.default.contentsOfDirectory(
            at: badMirror.appendingPathComponent(ManifestWriter.folderName),
            includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(mirrorManifests.isEmpty)
        XCTAssertNil(VerifyEngine.run(target: badMirror)?.total.nonZero,
                     "nothing verifiable under a mirror that was never written")
    }

    /// `partial` used to consult only cancel/halt, so a run that lost files to a
    /// failing destination still claimed completeness in the durable record.
    func testPartialIsSetWhenThatRootLostFiles() async throws {
        try XCTSkipIf(getuid() == 0, "root bypasses the permission bits this test relies on")
        let tmp = try freshTempDir()
        let library = try dir("lib", in: tmp)
        let bundles = try (1...2).map { try makeBundle("IMG_000\($0).JPG", byte: UInt8($0), in: tmp) }

        // The day-folder exists but is not writable, so `open(O_CREAT|O_EXCL)`
        // earns EACCES and every bundle fails at the primary. Readable (r-x) so
        // the collision scan and the dedup index still walk it normally — the
        // failure has to come from the *write*, not from planning.
        let dayDir = library.appendingPathComponent("2026/2026-05-28", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dayDir.path)

        let result = await ingest(bundles, primary: library, tmp: tmp)
        XCTAssertGreaterThan(result.filesFailed, 0, "the fixture must actually make the copy fail")

        let m = try manifest(in: library)
        XCTAssertEqual(m.partial, true, "a job that lost files must not record itself as complete")
        XCTAssertEqual(m.filesFailed, result.filesFailed)
    }

    /// Cancelling between the primary write and a mirror's leaves the mirror
    /// short. Both cancel tests in the suite were single-destination, so this
    /// path — the one where the two roots genuinely disagree — was untested.
    func testCancelWithMirrorsRecordsEachRootSeparately() async throws {
        let tmp = try freshTempDir()
        let library = try dir("lib", in: tmp)
        let mirror = try dir("nas", in: tmp)
        let bundles = try (1...6).map { try makeBundle("IMG_000\($0).JPG", byte: UInt8($0), in: tmp) }

        let result = await ingest(bundles, primary: library, archives: [mirror],
                                  tmp: tmp, cancelAfterBundles: 2)
        XCTAssertTrue(result.cancelled)

        let primaryManifest = try manifest(in: library)
        let mirrorManifest = try manifest(in: mirror)
        XCTAssertEqual(primaryManifest.partial, true)
        XCTAssertEqual(mirrorManifest.partial, true)
        XCTAssertGreaterThanOrEqual(primaryManifest.files.count, mirrorManifest.files.count,
                                    "the primary is written first, so it can only be ahead")

        // Whatever each manifest claims, verifying against its own root agrees.
        for root in [library, mirror] {
            let report = try XCTUnwrap(VerifyEngine.run(target: root))
            XCTAssertTrue(report.allGood,
                          "\(root.lastPathComponent) records exactly what landed there: \(report.issues)")
        }
    }
}

private extension Int {
    /// `nil` when zero, so an "expected nothing" assertion reads directly.
    var nonZero: Int? { self == 0 ? nil : self }
}
