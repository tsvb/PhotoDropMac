import XCTest
@testable import PhotoDropMac

/// S-2 — `heal` was a hash-equality oracle over arbitrary readable directories.
///
/// **Threat model.** A manifest's `destinations[]` is untrusted data, and anyone
/// who can drop one JSON into `<lib>/PhotoDrop Manifests/` — a shared NAS, a
/// synced folder, a library handed over on a drive — chooses what it says. Before
/// this gate, naming *any* directory as a mirror made `heal` stat and hash files
/// under it and report back whether the guessed digest matched, with `--script`
/// then emitting a `cp` from it. Reproduced with a synthetic attacker root and a
/// mode-600 dummy file: heal hashed it, named it as the restore source, and the
/// script copied from it. Both prior mitigations act *after* the fact — the hash
/// check only makes the answer correct, and the source-root header only helps if
/// a human reads it.
///
/// **The gate.** A recorded mirror is used only if it looks like a PhotoDrop
/// destination — every root written by a job carries its own
/// `PhotoDrop Manifests/` folder — or the user names it explicitly. Refused roots
/// are reported, never silently dropped: "we didn't look there" is exactly the
/// kind of quiet narrowing that makes a recovery tool lie by omission.
final class MirrorTrustTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorTrust-\(UUID().uuidString)", isDirectory: true)
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

    private func writeManifest(into root: URL, destinations: [URL], entries: [ManifestEntry]) throws {
        let manifest = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName,
            createdAt: Date(timeIntervalSince1970: 1_716_000_000), source: nil,
            primaryDestination: root.path(percentEncoded: false),
            archiveDestination: destinations.count > 1 ? destinations[1].path(percentEncoded: false) : nil,
            destinations: destinations.map { $0.path(percentEncoded: false) },
            verified: true, partial: false,
            filesCopied: entries.count, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: entries)
        XCTAssertNotNil(ManifestWriter.write(manifest, intoRoot: root,
                                             stamp: Date(timeIntervalSince1970: 1_716_000_000)))
    }

    /// Builds a library whose only file is missing, with `mirrorRoot` recorded as
    /// a mirror that *does* hold the file's bytes. Whether heal offers it is the
    /// question each test below answers.
    private func fixture(mirrorRoot: URL) throws -> (library: URL, digest: String) {
        let tmp = try freshTempDir()
        let library = tmp.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let digest = try writeFile("2026/IMG_0001.CR2", content: "the bytes", in: mirrorRoot)
        try writeManifest(into: library, destinations: [library, mirrorRoot], entries: [
            ManifestEntry(name: "IMG_0001.CR2", path: "2026/IMG_0001.CR2",
                          bytes: 9, xxhash64: digest, status: "verified"),
        ])
        return (library, digest)
    }

    func testAMirrorRootThatIsNotAPhotoDropDestinationIsRefused() throws {
        let tmp = try freshTempDir()
        let attacker = tmp.appendingPathComponent("someone-elses-documents", isDirectory: true)
        let (library, _) = try fixture(mirrorRoot: attacker)

        let report = try XCTUnwrap(HealEngine.run(target: library))
        let candidate = try XCTUnwrap(report.candidates.first)
        XCTAssertEqual(candidate.kind, .missing)
        XCTAssertNil(candidate.recoverableFrom,
                     "heal confirmed the contents of a directory the user never configured")
        XCTAssertEqual(report.refusedMirrorRoots, [attacker.path(percentEncoded: false)],
                       "a refused root must be reported, not silently dropped")
    }

    /// The gate must not break real mirrors. Every destination a job writes gets
    /// its own manifest folder, so that is the tell.
    func testARealMirrorRootIsStillUsed() throws {
        let tmp = try freshTempDir()
        let mirror = tmp.appendingPathComponent("nas", isDirectory: true)
        let (library, _) = try fixture(mirrorRoot: mirror)
        // What a genuine mirror carries: its own manifest of what landed there.
        try writeManifest(into: mirror, destinations: [mirror], entries: [
            ManifestEntry(name: "IMG_0001.CR2", path: "2026/IMG_0001.CR2",
                          bytes: 9, xxhash64: String(repeating: "0", count: 16), status: "verified"),
        ])

        let report = try XCTUnwrap(HealEngine.run(target: library))
        let candidate = try XCTUnwrap(report.candidates.first)
        XCTAssertEqual(candidate.recoverableFrom,
                       mirror.appendingPathComponent("2026/IMG_0001.CR2").path(percentEncoded: false))
        XCTAssertTrue(report.refusedMirrorRoots.isEmpty)
    }

    /// The escape hatch: a mirror written before mirrors carried their own
    /// manifests still recovers, if the *user* names it. That is the difference
    /// this gate is drawn on — the user's word, not the manifest's.
    func testAnExplicitlyAllowedRootIsUsedEvenWithoutAManifestFolder() throws {
        let tmp = try freshTempDir()
        let legacy = tmp.appendingPathComponent("old-backup", isDirectory: true)
        let (library, _) = try fixture(mirrorRoot: legacy)

        let report = try XCTUnwrap(HealEngine.run(target: library, allowedMirrorRoots: [legacy]))
        let candidate = try XCTUnwrap(report.candidates.first)
        XCTAssertEqual(candidate.recoverableFrom,
                       legacy.appendingPathComponent("2026/IMG_0001.CR2").path(percentEncoded: false))
        XCTAssertTrue(report.refusedMirrorRoots.isEmpty)
    }

    /// Containment still applies to an allowed root — permission to *read* a
    /// mirror is not permission for its recorded paths to leave it.
    func testAnAllowedRootStillContainsItsEntries() throws {
        let tmp = try freshTempDir()
        let mirror = tmp.appendingPathComponent("nas", isDirectory: true)
        let library = tmp.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let secret = try writeFile("secret.bin", content: "the bytes", in: tmp)

        try writeManifest(into: library, destinations: [library, mirror], entries: [
            ManifestEntry(name: "secret.bin", path: "../secret.bin",
                          bytes: 9, xxhash64: secret, status: "verified"),
        ])

        let report = try XCTUnwrap(HealEngine.run(target: library, allowedMirrorRoots: [mirror]))
        XCTAssertEqual(report.total, 0, "the escaping entry must be dropped before it is ever looked for")
    }
}
