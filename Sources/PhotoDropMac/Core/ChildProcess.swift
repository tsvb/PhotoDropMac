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
/// Nonisolated and safe to call from any actor: the wait is bridged through a
/// continuation rather than `waitUntilExit()`, so no thread is tied up.
enum ChildProcess {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var isSuccess: Bool { status == 0 }

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
    static func run(executable: URL,
                    arguments: [String],
                    environment: [String: String]? = nil) async throws -> Output {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let collected = Collected()
            let drains = DispatchGroup()
            for (pipe, stream) in [(outPipe, Collected.Stream.out), (errPipe, Collected.Stream.err)] {
                drains.enter()
                DispatchQueue.global(qos: .utility).async {
                    // Returns at EOF, which arrives when the child exits and
                    // Foundation has closed our copy of the write end.
                    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                    collected.set(data, for: stream)
                    drains.leave()
                }
            }

            process.terminationHandler = { @Sendable finished in
                // Both readers are at EOF by now (or about to be); notify keeps
                // this off the termination queue rather than blocking it.
                drains.notify(queue: DispatchQueue.global(qos: .utility)) {
                    continuation.resume(returning: Output(status: finished.terminationStatus,
                                                          stdout: collected.get(.out),
                                                          stderr: collected.get(.err)))
                }
            }

            do {
                try process.run()
            } catch {
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
        private let storage = OSAllocatedUnfairLock(initialState: (out: Data(), err: Data()))

        func set(_ data: Data, for stream: Stream) {
            storage.withLock { state in
                switch stream {
                case .out: state.out = data
                case .err: state.err = data
                }
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
    }
}
