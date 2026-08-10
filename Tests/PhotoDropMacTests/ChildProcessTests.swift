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

    // MARK: - S-7: bounded in time, output, and input

    /// The Tier-2 fix removed the deadlock; it did not bound the resource. A hook
    /// on a dead NFS mount, or one waiting on input, never returns — and `Copier`
    /// spawns it detached, so that is one leaked task per ingest, forever.
    func testATimeoutStopsAChildThatNeverExits() async throws {
        let s = try script("sleep 30")
        let started = Date()
        let out = try await ChildProcess.run(executable: s, arguments: [], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "the timeout did not fire")
        XCTAssertTrue(out.timedOut)
        XCTAssertFalse(out.isSuccess, "a killed child never succeeded, whatever its status says")
    }

    /// …and a child that finishes inside its budget is untouched, with a real
    /// exit status.
    func testAChildThatFinishesInTimeIsNotAffectedByTheTimeout() async throws {
        let s = try script("echo quick; exit 7")
        let out = try await ChildProcess.run(executable: s, arguments: [], timeout: 30)
        XCTAssertFalse(out.timedOut)
        XCTAssertEqual(out.status, 7)
        XCTAssertEqual(out.stdoutText, "quick")
    }

    /// Draining unboundedly is still accumulating unboundedly: a hook streaming
    /// gigabytes to stdout is held in this process's memory in full. Past the cap
    /// the bytes are read and dropped — reading has to continue or the child
    /// blocks in `write()`, which is the deadlock this type exists to prevent.
    func testOutputIsCappedButTheChildStillCompletes() async throws {
        let s = try script("""
        i=0
        while [ $i -lt 4096 ]; do printf '%0512d' $i; i=$((i+1)); done
        exit 5
        """)
        let out = try await ChildProcess.run(executable: s, arguments: [], maxOutputBytes: 64 * 1024)
        XCTAssertEqual(out.status, 5, "the child ran to completion rather than blocking on a full pipe")
        XCTAssertTrue(out.truncated)
        XCTAssertLessThanOrEqual(out.stdout.count, 64 * 1024)
        XCTAssertGreaterThan(out.stdout.count, 0, "what did fit is still reported")
    }

    /// stdin is `/dev/null`, not this process's. An inherited descriptor means a
    /// hook that reads input blocks on whatever the app happened to be attached
    /// to — in a GUI app, something nobody can type into.
    func testStdinIsNotInherited() async throws {
        let s = try script("cat; echo done")
        let out = try await ChildProcess.run(executable: s, arguments: [], timeout: 10)
        XCTAssertFalse(out.timedOut, "the child was left waiting on inherited stdin")
        XCTAssertEqual(out.stdoutText, "done")
    }
}
