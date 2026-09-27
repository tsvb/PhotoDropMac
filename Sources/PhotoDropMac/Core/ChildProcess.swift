import Foundation
import os

/// Runs a child process to completion and returns its exit status with both
/// output streams captured.
///
/// **The pipes are drained concurrently with the child's execution**, which is
/// the whole reason this exists. A pipe holds about 64 KiB; once it is full the
/// child blocks in `write()` and never exits, so any code that waits for exit
/// before reading — including the common shape of reading inside
/// `terminationHandler` — deadlocks on a child that produces more than a
/// bufferful. Measured: a post-ingest hook writing ~1 MiB to stdout never
/// returned, leaking a suspended task on every ingest. Readers are started
/// before `run()` and the wait completes only once both have hit EOF.
///
/// **And bounded in all three directions.** Draining is not the same as
/// bounding: the earlier fix stopped the child blocking on a full pipe, but left
/// this process accumulating its output without limit, waiting on it without
/// limit, and handing it our own stdin.
///
/// - `timeout` — a hook on a dropped mount, or one waiting for input, never
///   returns. `Copier` spawns the post-ingest hook in a detached task, so that
///   is one leaked task per ingest for the life of the process. On expiry the
///   child gets SIGTERM, then SIGKILL if it ignores that, and `timedOut` is set.
/// - `maxOutputBytes` — past the cap the bytes are read and dropped. Reading
///   must continue, or the child blocks in `write()` and we are back to the
///   original deadlock; only the *retention* is bounded.
/// - stdin is `/dev/null`. An inherited descriptor means a hook that reads input
///   blocks on whatever this process happened to be attached to — in a GUI app,
///   something nobody can type into.
///
/// Nonisolated and safe to call from any actor: the wait is bridged through a
/// continuation rather than `waitUntilExit()`, so no thread is tied up.
enum ChildProcess {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
        /// The child was killed for exceeding its budget. Its status is whatever
        /// the signal produced and means nothing about the work.
        var timedOut: Bool = false
        /// Output exceeded `maxOutputBytes`; what is here is a prefix.
        var truncated: Bool = false

        /// A killed child never succeeded, whatever exit status the signal left
        /// behind — callers branch on this to decide whether to report a failure.
        var isSuccess: Bool { status == 0 && !timedOut }

        /// Trimmed stderr as text — what these callers put in error messages.
        var stderrText: String {
            String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        var stdoutText: String {
            String(data: stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// Launches `executable`, waits for it to exit, and returns its status and
    /// output. Throws only if the process could not be launched at all (a
    /// missing or non-executable path); a non-zero exit is reported in
    /// `Output.status`, since for these callers that is data, not an error.
    ///
    /// `timeout` defaults to five minutes rather than to *none*: the callers here
    /// run `diskutil`, `launchctl` and a user hook, and a caller that never
    /// thought about the question should get a bound anyway. Pass a larger one
    /// where long work is legitimate (`PostIngestHook` does).
    static func run(executable: URL,
                    arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval? = 300,
                    maxOutputBytes: Int = 8 << 20,
                    drainGrace: TimeInterval = 5) async throws -> Output {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            let collected = Collected()
            let drains = DispatchGroup()
            for (pipe, stream) in [(outPipe, Collected.Stream.out), (errPipe, Collected.Stream.err)] {
                drains.enter()
                DispatchQueue.global(qos: .utility).async {
                    // Read to EOF in chunks, retaining at most `maxOutputBytes`.
                    // The reading itself never stops early: an unread pipe fills
                    // at ~64 KiB and the child then blocks in `write()` forever,
                    // which is the deadlock this whole type exists to prevent.
                    // Kept incrementally, so an answer given before EOF (see
                    // `drainGrace`) still carries what was read.
                    let handle = pipe.fileHandleForReading
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        collected.append(chunk, to: stream, limit: maxOutputBytes)
                    }
                    drains.leave()
                }
            }

            let killer = Killer(process: process)
            if let timeout {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    killer.killIfStillRunning()
                }
            }

            process.terminationHandler = { @Sendable finished in
                // Normally both readers reach EOF as the child exits. But EOF
                // arrives only when *every* holder of a pipe's write end has
                // closed it, and a grandchild the child left running — a hook's
                // `nohup rsync … &`, or a process that outlived SIGTERM to its
                // shell — inherits those ends and holds them for as long as it
                // lives. `run` then never returned: the timeout signals only the
                // direct child, which had already exited. So wait a bounded grace
                // for the drains and answer with what was read by then. A reader
                // still parked on the pipe stays parked until the grandchild lets
                // go; it holds nothing the answer needs.
                let status = finished.terminationStatus
                DispatchQueue.global(qos: .utility).async {
                    let drained = drains.wait(timeout: .now() + drainGrace) == .success
                    continuation.resume(returning: Output(status: status,
                                                          stdout: collected.get(.out),
                                                          stderr: collected.get(.err),
                                                          timedOut: killer.didKill,
                                                          truncated: collected.wasTruncated || !drained))
                }
            }

            do {
                try process.run()
            } catch {
                killer.cancel()
                // The child never spawned, so nothing will ever close the write
                // ends and the two readers would block forever. Close them here
                // so they see EOF and their threads are released.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }

    /// Lock-guarded output accumulator; the two drain queues write different
    /// streams, and the reader runs only after both have finished.
    private final class Collected: Sendable {
        enum Stream { case out, err }
        private let storage = OSAllocatedUnfairLock(
            initialState: (out: Data(), err: Data(), truncated: false))

        /// Appends `chunk`, keeping at most `limit` bytes per stream. Bytes past
        /// the limit are dropped, never left unread — see the drain loop.
        func append(_ chunk: Data, to stream: Stream, limit: Int) {
            storage.withLock { state in
                let room = limit - (stream == .out ? state.out.count : state.err.count)
                if room > 0 {
                    switch stream {
                    case .out: state.out.append(chunk.prefix(room))
                    case .err: state.err.append(chunk.prefix(room))
                    }
                }
                if chunk.count > room { state.truncated = true }
            }
        }

        func get(_ stream: Stream) -> Data {
            storage.withLock { state in
                switch stream {
                case .out: return state.out
                case .err: return state.err
                }
            }
        }

        var wasTruncated: Bool { storage.withLock { $0.truncated } }
    }

    /// The timeout's teeth. SIGTERM first so a well-behaved child can clean up,
    /// SIGKILL a moment later so a badly-behaved one still dies — the point is
    /// that `run` always returns. Idempotent and lock-guarded: the timer fires on
    /// its own queue and races both a normal exit and a failed spawn.
    private final class Killer: Sendable {
        private let process: Process
        private let state = OSAllocatedUnfairLock(initialState: (killed: false, cancelled: false))

        init(process: Process) { self.process = process }

        var didKill: Bool { state.withLock { $0.killed } }

        func cancel() { state.withLock { $0.cancelled = true } }

        func killIfStillRunning() {
            let shouldKill = state.withLock { state -> Bool in
                guard !state.cancelled, !state.killed else { return false }
                state.killed = true
                return true
            }
            guard shouldKill, process.isRunning else {
                if shouldKill { state.withLock { $0.killed = false } }   // it had already exited
                return
            }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [process] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
