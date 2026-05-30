import Foundation

/// Error thrown when the post-ingest hook can't run or exits non-zero.
struct PostIngestHookError: Error, Sendable {
    let message: String
}

/// Runs a user-configured executable after a completed ingest, describing the
/// job through environment variables (git-hook style). Best-effort: a missing or
/// failing hook is logged, never fatal to the ingest. The script is launched as
/// an argument vector (no shell), like `DriveEjector`, so a destination path with
/// spaces or shell metacharacters can't be misinterpreted.
///
/// Contract: the configured path must be an executable file (a shebang script
/// with `chmod +x`, or a binary). argv[1] is the primary destination path; the
/// job result is in the environment (see `environment(for:)`).
enum PostIngestHook {
    static let defaultsKey = "photodrop.postIngestScript"

    /// Environment describing the finished job, merged over the current process
    /// environment so the hook still inherits PATH etc.
    static func environment(for result: CopyResult) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PHOTODROP_PRIMARY"] = result.primaryDestination.path(percentEncoded: false)
        env["PHOTODROP_FILES_COPIED"] = String(result.filesCopied)
        env["PHOTODROP_FILES_SKIPPED"] = String(result.filesSkipped)
        env["PHOTODROP_FILES_FAILED"] = String(result.filesFailed)
        env["PHOTODROP_TOTAL_BYTES"] = String(result.totalBytes)
        env["PHOTODROP_HALTED"] = result.halted ? "1" : "0"
        if let manifestURL = result.manifestURL {
            env["PHOTODROP_MANIFEST"] = manifestURL.path(percentEncoded: false)
        }
        if let logURL = result.logURL {
            env["PHOTODROP_LOG"] = logURL.path(percentEncoded: false)
        }
        return env
    }

    /// Launches `scriptPath` with the primary destination as argv[1] and the
    /// job result in the environment. Throws `PostIngestHookError` if the file
    /// isn't an executable that can be launched, or if it exits non-zero. The
    /// blocking wait is bridged through a continuation, mirroring `DriveEjector`.
    static func run(scriptPath: String, result: CopyResult) async throws {
        let env = environment(for: result)
        let primaryPath = result.primaryDestination.path(percentEncoded: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: scriptPath)
            process.arguments = [primaryPath]
            process.environment = env
            process.standardOutput = Pipe()   // don't leak hook chatter to our stdout
            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            process.terminationHandler = { @Sendable finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let message = text.isEmpty
                        ? "Post-ingest hook exited with status \(finished.terminationStatus)."
                        : text
                    continuation.resume(throwing: PostIngestHookError(message: message))
                }
            }

            do {
                try process.run()
            } catch {
                // run() fails synchronously if the path isn't an executable file;
                // the termination handler never fires, so resume here.
                continuation.resume(throwing: PostIngestHookError(message: error.localizedDescription))
            }
        }
    }
}
