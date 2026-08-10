import XCTest
@testable import PhotoDropMac

/// The report-only heal engine: classifies damaged/missing files as recoverable
/// (a verified mirror copy exists) or not, and never writes to the library.
final class HealEngineTests: XCTestCase {
    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacHealTests-\(UUID().uuidString)", isDirectory: true)
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

    private func writeManifest(into primary: URL, destinations: [URL], _ entries: [ManifestEntry]) throws {
        let stamp = Date(timeIntervalSince1970: 1_716_000_000)
        let m = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName, createdAt: stamp, source: nil,
            primaryDestination: primary.path(percentEncoded: false),
            archiveDestination: destinations.count > 1 ? destinations[1].path(percentEncoded: false) : nil,
            destinations: destinations.map { $0.path(percentEncoded: false) },
            verified: true, partial: false, filesCopied: entries.count, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: entries)
        XCTAssertNotNil(ManifestWriter.write(m, intoRoot: primary, stamp: stamp))
        // Every root a job writes gets its own manifest, and that is what marks a
        // recorded mirror as a PhotoDrop destination rather than an arbitrary
        // directory a crafted manifest named — see `VerifyEngine.build`'s mirror
        // gate, and `MirrorTrustTests` for the gate itself. These fixtures are
        // real mirrors, so they carry the folder real mirrors carry.
        for mirror in destinations.dropFirst() {
            XCTAssertNotNil(ManifestWriter.write(m, intoRoot: mirror, stamp: stamp))
        }
    }

    private func entry(_ path: String, hash: String) -> ManifestEntry {
        ManifestEntry(name: (path as NSString).lastPathComponent, path: path, bytes: 0, xxhash64: hash, status: "verified")
    }

    func testAllHealthy() throws {
        let tmp = try freshTempDir()
        let primary = tmp.appendingPathComponent("primary", isDirectory: true)
        let mirror = tmp.appendingPathComponent("mirror", isDirectory: true)
        let h = try writeFile("2026/a.bin", content: "good", in: primary)
        try writeFile("2026/a.bin", content: "good", in: mirror)
        try writeManifest(into: primary, destinations: [primary, mirror], [entry("2026/a.bin", hash: h)])

        let report = try XCTUnwrap(HealEngine.run(target: primary))
        XCTAssertTrue(report.allHealthy)
        XCTAssertEqual(report.healthy, 1)
    }

    func testChangedPrimaryRecoverableFromMirror() throws {
        let tmp = try freshTempDir()
        let primary = tmp.appendingPathComponent("primary", isDirectory: true)
        let mirror = tmp.appendingPathComponent("mirror", isDirectory: true)
        let h = try writeFile("2026/a.bin", content: "good", in: primary)
        try writeFile("2026/a.bin", content: "good", in: mirror)
        try writeManifest(into: primary, destinations: [primary, mirror], [entry("2026/a.bin", hash: h)])
        try Data("corrupted".utf8).write(to: primary.appendingPathComponent("2026/a.bin"))

        let report = try XCTUnwrap(HealEngine.run(target: primary))
        XCTAssertEqual(report.candidates.count, 1)
        XCTAssertEqual(report.recoverable.count, 1)
        let c = try XCTUnwrap(report.recoverable.first)
        XCTAssertEqual(c.kind, .changed)
        XCTAssertEqual(c.recoverableFrom, mirror.appendingPathComponent("2026/a.bin").path(percentEncoded: false))
    }

    func testMissingPrimaryRecoverableFromMirror() throws {
        let tmp = try freshTempDir()
        let primary = tmp.appendingPathComponent("primary", isDirectory: true)
        let mirror = tmp.appendingPathComponent("mirror", isDirectory: true)
        let h = try writeFile("2026/a.bin", content: "good", in: primary)
        try writeFile("2026/a.bin", content: "good", in: mirror)
        try writeManifest(into: primary, destinations: [primary, mirror], [entry("2026/a.bin", hash: h)])
        try FileManager.default.removeItem(at: primary.appendingPathComponent("2026/a.bin"))

        let report = try XCTUnwrap(HealEngine.run(target: primary))
        XCTAssertEqual(report.recoverable.count, 1)
        XCTAssertEqual(report.recoverable.first?.kind, .missing)
    }

    func testUnrecoverableWhenNoGoodMirror() throws {
        let tmp = try freshTempDir()
        let primary = tmp.appendingPathComponent("primary", isDirectory: true)
        let h = try writeFile("2026/a.bin", content: "good", in: primary)
        try writeManifest(into: primary, destinations: [primary], [entry("2026/a.bin", hash: h)])   // no mirror
        try Data("corrupted".utf8).write(to: primary.appendingPathComponent("2026/a.bin"))

        let report = try XCTUnwrap(HealEngine.run(target: primary))
        XCTAssertEqual(report.unrecoverable.count, 1)
        XCTAssertNil(report.unrecoverable.first?.recoverableFrom)
        XCTAssertFalse(report.allHealthy)
    }

    // MARK: - The manifest is untrusted input

    /// Regression: `heal` must apply the same trust rule as `verify`.
    ///
    /// It used to merge manifests oldest→newest and let the newest win. Because
    /// `createdAt` is chosen by whoever writes the file, dropping one JSON dated
    /// 2099 that records a *tampered* file's current digest was enough to make
    /// `heal` report the corrupted library completely healthy — while `verify`,
    /// which refuses to arbitrate, correctly flagged the disagreement. Measured
    /// before the fix: `verify` → conflicts=1, `heal` → healthy=1, candidates=0.
    func testPlantedNewerManifestCannotMarkTamperedFileHealthy() throws {
        let tmp = try freshTempDir()
        let primary = tmp.appendingPathComponent("primary", isDirectory: true)
        let good = try writeFile("2026/a.bin", content: "good", in: primary)
        try writeManifest(into: primary, destinations: [primary], [entry("2026/a.bin", hash: good)])

        // Tamper, then plant a far-future manifest blessing the tampered bytes.
        let target = primary.appendingPathComponent("2026/a.bin")
        try Data("tampered".utf8).write(to: target)
        let tampered = String(format: "%016llx", try XxHash64.hash(fileAt: target))
        let planted = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName,
            createdAt: Date(timeIntervalSince1970: 4_102_444_800),   // 2100-01-01
            source: nil, primaryDestination: primary.path(percentEncoded: false),
            archiveDestination: nil, destinations: [primary.path(percentEncoded: false)],
            verified: true, partial: false, filesCopied: 1, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0,
            files: [entry("2026/a.bin", hash: tampered)])
        XCTAssertNotNil(ManifestWriter.write(planted, intoRoot: primary,
                                             stamp: Date(timeIntervalSince1970: 4_102_444_800)))

        let report = try XCTUnwrap(HealEngine.run(target: primary))
        XCTAssertFalse(report.allHealthy, "a planted manifest must not certify a tampered library")
        XCTAssertEqual(report.healthy, 0)
        XCTAssertEqual(report.candidates.count, 1)
        XCTAssertEqual(report.candidates.first?.kind, .conflicted)
        XCTAssertNil(report.candidates.first?.recoverableFrom,
                     "a conflicted file has no expected digest to heal towards")

        // And the two engines now agree about the same library.
        let verify = try XCTUnwrap(VerifyEngine.run(target: primary))
        XCTAssertEqual(verify.conflicts, 1)
    }

    /// The benign case must stay quiet: a re-ingest re-records what it skipped,
    /// so two manifests agreeing on a digest is normal and not a conflict.
    func testAgreeingManifestsAreNotAConflict() throws {
        let tmp = try freshTempDir()
        let primary = tmp.appendingPathComponent("primary", isDirectory: true)
        let h = try writeFile("2026/a.bin", content: "good", in: primary)
        try writeManifest(into: primary, destinations: [primary], [entry("2026/a.bin", hash: h)])
        // A second manifest recording the same digest, written later.
        let second = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName,
            createdAt: Date(timeIntervalSince1970: 1_717_000_000), source: nil,
            primaryDestination: primary.path(percentEncoded: false), archiveDestination: nil,
            destinations: [primary.path(percentEncoded: false)], verified: true, partial: false,
            filesCopied: 0, filesSkipped: 1, filesFailed: 0, totalBytes: 0, elapsedSeconds: 0,
            files: [entry("2026/a.bin", hash: h)])
        XCTAssertNotNil(ManifestWriter.write(second, intoRoot: primary,
                                             stamp: Date(timeIntervalSince1970: 1_717_000_000)))

        let report = try XCTUnwrap(HealEngine.run(target: primary))
        XCTAssertTrue(report.allHealthy)
        XCTAssertEqual(report.healthy, 1, "the file is counted once, not once per manifest")
    }

    /// Mirrors recorded by *agreeing* manifests are pooled, so a healthy copy
    /// found by any of them is offered. Safe because a mirror is only ever used
    /// after its bytes hash to the expected digest.
    func testMirrorsFromAgreeingManifestsArePooled() throws {
        let tmp = try freshTempDir()
        let primary = tmp.appendingPathComponent("primary", isDirectory: true)
        let mirrorA = tmp.appendingPathComponent("mirrorA", isDirectory: true)
        let mirrorB = tmp.appendingPathComponent("mirrorB", isDirectory: true)
        let h = try writeFile("2026/a.bin", content: "good", in: primary)
        try writeFile("2026/a.bin", content: "good", in: mirrorB)   // only B holds a copy
        try writeManifest(into: primary, destinations: [primary, mirrorA],
                          [entry("2026/a.bin", hash: h)])
        let second = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName,
            createdAt: Date(timeIntervalSince1970: 1_717_000_000), source: nil,
            primaryDestination: primary.path(percentEncoded: false),
            archiveDestination: mirrorB.path(percentEncoded: false),
            destinations: [primary.path(percentEncoded: false), mirrorB.path(percentEncoded: false)],
            verified: true, partial: false, filesCopied: 0, filesSkipped: 1, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: [entry("2026/a.bin", hash: h)])
        XCTAssertNotNil(ManifestWriter.write(second, intoRoot: primary,
                                             stamp: Date(timeIntervalSince1970: 1_717_000_000)))
        // mirrorB is a real destination of that second job, so it carries its own
        // manifest — the mark `VerifyEngine.build`'s mirror gate looks for.
        XCTAssertNotNil(ManifestWriter.write(second, intoRoot: mirrorB,
                                             stamp: Date(timeIntervalSince1970: 1_717_000_000)))

        try FileManager.default.removeItem(at: primary.appendingPathComponent("2026/a.bin"))

        let report = try XCTUnwrap(HealEngine.run(target: primary))
        XCTAssertEqual(report.recoverable.count, 1, "the second manifest's mirror must still be searched")
        XCTAssertEqual(report.recoverable.first?.recoverableFrom,
                       mirrorB.appendingPathComponent("2026/a.bin").path(percentEncoded: false))
    }

    func testRestoreScriptListsRecoverable() throws {
        let candidate = HealCandidate(relPath: "2026/a.bin", kind: .changed,
                                      badPath: "/lib/2026/a.bin", recoverableFrom: "/nas/2026/a.bin")
        let report = HealReport(healthy: 0, candidates: [candidate], manifestCount: 1)
        let script = HealEngine.restoreScript(report)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("cp -p '/nas/2026/a.bin' '/lib/2026/a.bin'"), script)
    }
}
