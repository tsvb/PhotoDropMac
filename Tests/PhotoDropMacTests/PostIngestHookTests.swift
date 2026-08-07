import XCTest
@testable import PhotoDropMac

/// The post-ingest hook: it exposes the job in `PHOTODROP_*` env vars, runs the
/// configured executable with the destination as argv[1], and treats a missing
/// or non-zero-exit script as an error (which the copier reports, best-effort).
final class PostIngestHookTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacHookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func result(primary: URL, copied: Int = 3, skipped: Int = 0, failed: Int = 0,
                        bytes: Int64 = 1234) -> CopyResult {
        CopyResult(bundleCount: copied, filesCopied: copied, filesSkipped: skipped, filesFailed: failed,
                   failuresByDestination: [:],
                   totalBytes: bytes, elapsedSeconds: 1, primaryDestination: primary,
                   logURL: nil, manifestURL: nil, wasEjected: false, halted: false,
                   haltReason: nil, cancelled: false)
    }

    @discardableResult
    private func writeScript(_ body: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("hook.sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testEnvironmentExposesJobDetails() {
        let env = PostIngestHook.environment(for: result(primary: URL(fileURLWithPath: "/lib"),
                                                         copied: 7, skipped: 2, failed: 1, bytes: 99))
        XCTAssertEqual(env["PHOTODROP_PRIMARY"], "/lib")
        XCTAssertEqual(env["PHOTODROP_FILES_COPIED"], "7")
        XCTAssertEqual(env["PHOTODROP_FILES_SKIPPED"], "2")
        XCTAssertEqual(env["PHOTODROP_FILES_FAILED"], "1")
        XCTAssertEqual(env["PHOTODROP_TOTAL_BYTES"], "99")
        XCTAssertEqual(env["PHOTODROP_HALTED"], "0")
        XCTAssertNotNil(env["PATH"], "the hook inherits the process environment")
    }

    func testRunsScriptWithArgAndEnvironment() async throws {
        let dir = try freshTempDir()
        let out = dir.appendingPathComponent("out.txt")
        let primary = dir.appendingPathComponent("library", isDirectory: true)
        let primaryPath = primary.path(percentEncoded: false)
        let script = try writeScript("""
        {
          echo "ARG1=$1"
          echo "COPIED=$PHOTODROP_FILES_COPIED"
          echo "FAILED=$PHOTODROP_FILES_FAILED"
          echo "PRIMARY=$PHOTODROP_PRIMARY"
        } > "\(out.path)"
        """, in: dir)

        try await PostIngestHook.run(scriptPath: script.path,
                                     result: result(primary: primary, copied: 4, failed: 1))

        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(text.contains("ARG1=\(primaryPath)"), text)
        XCTAssertTrue(text.contains("COPIED=4"), text)
        XCTAssertTrue(text.contains("FAILED=1"), text)
        XCTAssertTrue(text.contains("PRIMARY=\(primaryPath)"), text)
    }

    func testNonZeroExitThrows() async throws {
        let dir = try freshTempDir()
        let script = try writeScript("exit 3\n", in: dir)
        do {
            try await PostIngestHook.run(scriptPath: script.path, result: result(primary: dir))
            XCTFail("a non-zero exit must throw")
        } catch is PostIngestHookError { /* expected */ }
    }

    func testMissingExecutableThrows() async throws {
        let dir = try freshTempDir()
        do {
            try await PostIngestHook.run(scriptPath: dir.appendingPathComponent("nope.sh").path,
                                         result: result(primary: dir))
            XCTFail("a missing executable must throw")
        } catch is PostIngestHookError { /* expected */ }
    }
}
