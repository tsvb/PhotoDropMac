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
        // stdout is captured and discarded rather than left unredirected, so
        // diskutil's success chatter never leaks to the app's stdout.
        // `ChildProcess` drains both streams while the child runs; diskutil is
        // quiet enough that it never filled a pipe buffer, but the deadlock that
        // shape produces is real (it bit the post-ingest hook), so the pattern
        // lives in one place now.
        let output = try await ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            arguments: arguments)

        guard output.isSuccess else {
            let text = output.stderrText
            throw EjectError(
                exitCode: output.status,
                message: text.isEmpty ? "diskutil exited with status \(output.status)" : text
            )
        }
    }
}

/// How an eject is reported to the user.
///
/// The sidebar's eject button was `Task { try? await DriveEjector.eject(…) }` —
/// neither outcome reported. Eject is the one irreversible act in this app, and
/// "did it work?" is the entire question; `IngestEngine` already logs its own
/// eject failures, so this was the sink that was missed.
enum EjectOutcome {
    /// The card label is card-authored text going into an alert, so it is
    /// neutralized like every other sink — see `SafeText`.
    static func failureMessage(card: String, error: String) -> String {
        "Couldn’t eject \(SafeText.display(card)): \(SafeText.display(error))"
    }
}
