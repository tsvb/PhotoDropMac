import Foundation

/// Error thrown when `diskutil eject` exits non-zero.
///
/// `message` is the captured stderr (trimmed) when available, otherwise a
/// synthesized fallback describing the exit code.
struct EjectError: Error, Sendable {
    let exitCode: Int32
    let message: String
}

/// Ejects a mounted removable volume via `/usr/sbin/diskutil eject`.
///
/// Shells out to `diskutil` rather than using DiskArbitration because:
///   - the app runs unsandboxed ad-hoc signed, so `Process` is unrestricted;
///   - `diskutil` handles the full unmount-then-eject dance, including
///     detaching the parent whole-disk, with one call;
///   - no entitlements are required.
///
/// The methods are nonisolated and safe to call from any actor. The blocking
/// `Process.waitUntilExit()` is avoided entirely — we wire `Process`'s
/// `terminationHandler` into a `withCheckedThrowingContinuation`, so the
/// calling task suspends without tying up a thread.
enum DriveEjector {
    /// Ejects the volume mounted at `mountPoint` (e.g. `/Volumes/SanDisk`).
    ///
    /// Throws `EjectError` if `diskutil` exits non-zero. Returns normally on
    /// success.
    static func eject(mountPoint: String) async throws {
        try await run(arguments: ["eject", mountPoint])
    }

    /// Convenience: ejects the volume at `url`, using its filesystem path as
    /// the `diskutil` target.
    static func eject(url: URL) async throws {
        try await eject(mountPoint: url.path(percentEncoded: false))
    }

    private static func run(arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = arguments

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            // Discard stdout — diskutil's success chatter is not useful here
            // and leaving it unredirected would let it leak to the app's
            // stdout.
            process.standardOutput = Pipe()

            // The termination handler fires on an internal queue once the
            // child exits. Reading to EOF here is safe because the child has
            // closed its end of the pipe.
            process.terminationHandler = { @Sendable finished in
                let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderrText = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = stderrText.isEmpty
                        ? "diskutil exited with status \(finished.terminationStatus)"
                        : stderrText
                    continuation.resume(throwing: EjectError(
                        exitCode: finished.terminationStatus,
                        message: message
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                // `run()` can fail synchronously if the executable is missing
                // or the arguments can't be encoded. In that case the
                // terminationHandler never fires, so we must resume here.
                continuation.resume(throwing: error)
            }
        }
    }
}
