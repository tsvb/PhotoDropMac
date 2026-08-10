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
        let output: ChildProcess.Output
        do {
            // Both streams are drained while the hook runs — a hook that prints
            // more than a pipe buffer (`rsync -v`, `exiftool`) used to wedge here
            // forever. See ChildProcess.
            // An hour, not the shared five-minute default: a hook that rsyncs the
            // library to a NAS is doing legitimate long work, and killing it
            // would be worse than the leak. It is still *bounded* — a hook on a
            // dropped mount used to hang forever, and `Copier` runs this in a
            // detached task, so that was one leaked task per ingest.
            output = try await ChildProcess.run(
                executable: URL(fileURLWithPath: scriptPath),
                arguments: [result.primaryDestination.path(percentEncoded: false)],
                environment: environment(for: result),
                timeout: 3600)
        } catch {
            // Launch failed outright — the path isn't an executable file.
            throw PostIngestHookError(message: error.localizedDescription)
        }

        guard output.isSuccess else {
            if output.timedOut {
                throw PostIngestHookError(message: "Post-ingest hook was still running after an hour and was stopped.")
            }
            let text = output.stderrText
            throw PostIngestHookError(message: text.isEmpty
                ? "Post-ingest hook exited with status \(output.status)."
                : text)
        }
    }
}
