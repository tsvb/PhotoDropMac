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
            verified: true, filesCopied: entries.count, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: entries)
        XCTAssertNotNil(ManifestWriter.write(m, intoRoot: primary, stamp: stamp))
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

    func testRestoreScriptListsRecoverable() throws {
        let candidate = HealCandidate(relPath: "2026/a.bin", kind: .changed,
                                      badPath: "/lib/2026/a.bin", recoverableFrom: "/nas/2026/a.bin")
        let report = HealReport(healthy: 0, candidates: [candidate], manifestCount: 1)
        let script = HealEngine.restoreScript(report)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("cp -p '/nas/2026/a.bin' '/lib/2026/a.bin'"), script)
    }
}
