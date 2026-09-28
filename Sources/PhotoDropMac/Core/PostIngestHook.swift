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

    /// Whether a finished job earns the hook — **one definition for both front
    /// ends.** The app ran it after any job that was neither halted nor
    /// cancelled, including one that lost files to a full disk or a permission
    /// error, while the CLI already required the primary to be whole. A hook is
    /// where "this card is done" automation lives — archive it, wipe it, tell
    /// someone — so running it over a library missing photos, or one whose
    /// receipt could not be written, is the one outcome it must not have.
    ///
    /// `cardFullyTaken` is the other half of "done", the half the result cannot
    /// see: whether the job took **everything on the card**. The gate checked
    /// only the result, so a scan that could not open a folder, found files it
    /// does not ingest, or had frames deselected in the contact sheet still ran
    /// the hook — the eject was withheld for exactly those cases, and a "wipe the
    /// card" hook then destroyed what the eject gate had been protecting. Same
    /// rule as the eject: the caller passes what it passes there.
    static func shouldRun(after result: CopyResult, cardFullyTaken: Bool) -> Bool {
        cardFullyTaken && !result.halted && !result.cancelled
            && result.primaryFailures == 0 && result.manifestFailures.isEmpty
    }

    /// Resolves the configured hook to the file that will actually run, or says
    /// why it must not.
    ///
    /// The path is a preference, and nothing checked it: whatever it named was
    /// launched. That matters for two reasons beyond a typo.
    ///
    /// - **A card can supply it.** A hook under `/Volumes/<name>/…` names
    ///   whatever is mounted under that name when the ingest finishes, and a card
    ///   labelled the same (exFAT reads every file as executable and carries no
    ///   quarantine) would have its own script run. `ScheduledVerification`
    ///   already refuses a tool on a removable volume for the same reason; the
    ///   hook did not.
    /// - **Other accounts can change it.** A script, or a folder above it, that
    ///   another user can write (`/Users/Shared`, `/tmp`, a group-writable
    ///   `staff` folder) is a script someone else chooses.
    ///
    /// So: the link-free path must be a regular file, and it and every folder
    /// above it must be owned by this user or root and not writable by anyone
    /// else. Group write is tolerated only for `wheel` and `admin`, whose members
    /// can already become root (`/Applications` is `root:admin 775`). The
    /// resolved path is returned so the caller runs the file that was checked,
    /// not whatever the link points at a moment later.
    ///
    /// What this does **not** stop is a process running as *this* user rewriting
    /// the preference — see SECURITY.md. The ingest screen names the hook before
    /// every ingest for that reason.
    static func validate(scriptPath: String) throws -> URL {
        let shown = SafeText.display(scriptPath)
        guard let buffer = realpath(scriptPath, nil) else {
            throw PostIngestHookError(message: "Post-ingest hook “\(shown)” was not found.")
        }
        let resolved = String(cString: buffer)
        free(buffer)

        var info = stat()
        guard lstat(resolved, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw PostIngestHookError(message: "Post-ingest hook “\(shown)” is not a file.")
        }
        guard isProtected(info) else {
            throw PostIngestHookError(message:
                "Post-ingest hook “\(shown)” was not run: other users can change it. "
                + "Remove group and other write permission (chmod go-w).")
        }
        var folder = (resolved as NSString).deletingLastPathComponent
        while true {
            guard lstat(folder, &info) == 0, isProtected(info) else {
                throw PostIngestHookError(message:
                    "Post-ingest hook “\(shown)” was not run: other users can change the folder "
                    + "“\(SafeText.display(folder))” it is in. Keep the script in a folder only you can write to.")
            }
            if folder == "/" { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        let url = URL(fileURLWithPath: resolved)
        if ScheduledVerification.isOnRemovableVolume(url) {
            throw PostIngestHookError(message:
                "Post-ingest hook “\(shown)” was not run: it is on a removable volume, and a card mounted "
                + "under the same name would supply its own script. Keep the script on your startup disk.")
        }
        return url
    }

    /// Owned by this user or root, and writable by no one else — except the
    /// `wheel` (0) and `admin` (80) groups, which can already become root.
    private static func isProtected(_ info: stat) -> Bool {
        guard info.st_uid == getuid() || info.st_uid == 0 else { return false }
        if info.st_mode & 0o002 != 0 { return false }
        if info.st_mode & 0o020 != 0, info.st_gid != 0, info.st_gid != 80 { return false }
        return true
    }

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
    /// fails `validate(scriptPath:)`, isn't an executable that can be launched,
    /// or exits non-zero. The
    /// blocking wait is bridged through a continuation, mirroring `DriveEjector`.
    static func run(scriptPath: String, result: CopyResult) async throws {
        let executable = try validate(scriptPath: scriptPath)
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
                executable: executable,
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
