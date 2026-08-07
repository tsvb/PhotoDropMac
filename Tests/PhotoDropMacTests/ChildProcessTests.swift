import XCTest
@testable import PhotoDropMac

/// The shared subprocess runner. Previously exercised only indirectly through
/// `PostIngestHookTests`, despite being the single place three call sites
/// (`PostIngestHook`, `DriveEjector`, `ScheduledVerification`) get their
/// deadlock-freedom from.
final class ChildProcessTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChildProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    @discardableResult
    private func script(_ body: String, named name: String = "s.sh") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testCapturesStdoutStderrAndStatus() async throws {
        let s = try script("echo out; echo err 1>&2; exit 3")
        let out = try await ChildProcess.run(executable: s, arguments: [])
        XCTAssertEqual(out.status, 3)
        XCTAssertFalse(out.isSuccess)
        XCTAssertEqual(out.stdoutText, "out")
        XCTAssertEqual(out.stderrText, "err")
    }

    func testPassesArgumentsAsArgvNotThroughAShell() async throws {
        // If arguments went through a shell, the `;` and `$(…)` would execute.
        let s = try script("printf '%s' \"$1\"")
        let hostile = "a; touch \(dir.appendingPathComponent("pwned").path); $(id)"
        let out = try await ChildProcess.run(executable: s, arguments: [hostile])
        XCTAssertEqual(out.stdoutText, hostile, "argv is passed verbatim")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwned").path),
                       "no shell interpretation of arguments")
    }

    func testPassesEnvironment() async throws {
        let s = try script("printf '%s' \"$PHOTODROP_TEST\"")
        let out = try await ChildProcess.run(executable: s, arguments: [],
                                             environment: ["PHOTODROP_TEST": "hello"])
        XCTAssertEqual(out.stdoutText, "hello")
    }

    /// The reason this type exists. A pipe holds ~64 KiB; reading it only after
    /// the child exits means any child that prints more than that blocks in
    /// `write()` forever. Measured before the fix: ~1 MiB of stdout never
    /// returned.
    func testDrainsMoreThanAPipeBufferOnBothStreams() async throws {
        let s = try script("""
        i=0
        while [ $i -lt 8192 ]; do
          printf '%064d\\n' $i
          printf '%064d\\n' $i 1>&2
          i=$((i+1))
        done
        """)
        let out = try await ChildProcess.run(executable: s, arguments: [])
        XCTAssertEqual(out.status, 0)
        XCTAssertGreaterThan(out.stdout.count, 512 * 1024, "~512 KiB of stdout came back intact")
        XCTAssertGreaterThan(out.stderr.count, 512 * 1024, "…and of stderr")
    }

    func testThrowsWhenTheExecutableCannotBeLaunched() async throws {
        do {
            _ = try await ChildProcess.run(executable: dir.appendingPathComponent("nope"), arguments: [])
            XCTFail("launching a nonexistent path must throw")
        } catch {
            // Expected.
        }
    }

    /// A failed spawn must not strand the two drain threads waiting on pipes
    /// nothing will ever close. Ten failures in a row would exhaust the pool if
    /// the write ends were left open.
    func testRepeatedLaunchFailuresDoNotStrandReaders() async throws {
        for _ in 0..<10 {
            _ = try? await ChildProcess.run(executable: dir.appendingPathComponent("nope"), arguments: [])
        }
        // Still responsive afterwards.
        let s = try script("echo alive")
        let out = try await ChildProcess.run(executable: s, arguments: [])
        XCTAssertEqual(out.stdoutText, "alive")
    }

    func testNonZeroExitIsDataNotAnError() async throws {
        let s = try script("exit 42")
        let out = try await ChildProcess.run(executable: s, arguments: [])
        XCTAssertEqual(out.status, 42, "callers decide what a non-zero exit means")
    }
}
