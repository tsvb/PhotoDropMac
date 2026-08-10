import Foundation

/// Locates the `photodrop` command-line tool that ships inside the app bundle
/// (embedded at `Contents/MacOS/photodrop` by the build — see `project.yml`).
///
/// Lives in the UI layer on purpose: `Core/` is also compiled into the headless
/// `photodrop` tool itself, so bundle-relative assumptions must not leak there.
/// The scheduled-verification feature uses this to default its CLI path, so a
/// distributed build "just works" without the user building the tool by hand.
enum EmbeddedCLI {
    /// URL of the bundled `photodrop`, or `nil` if it isn't present (e.g. a
    /// stripped build). Checks `Contents/MacOS` first, then `Contents/Helpers`
    /// as a fallback so the helper is agnostic to the bundle layout.
    static var url: URL? { resolve(in: Bundle.main) }

    /// The lookup, with the bundle injected so it is testable.
    ///
    /// **The paths are constructed here rather than asked of Foundation.**
    /// `Bundle.url(forAuxiliaryExecutable:)` is not dependable across OS
    /// versions: on macOS 26 it returns a constructed path, and on macOS 15 —
    /// inside the deployment range, and what CI runs — it returned **nil for a
    /// real, correctly-embedded app bundle**. That failure is silent and lands
    /// in the worst place: `MaintenancePreferences` uses this for the scheduled
    /// verification's default binary path, so the nightly job that exists to
    /// tell you something is wrong would simply never have one. Caught by CI
    /// building on the older toolchain; it would otherwise have shipped as
    /// "scheduled verify doesn't work on macOS 14/15".
    ///
    /// Every candidate is held to `isExecutableFile`, which is an existence and
    /// permission claim — the original primary branch returned a path Foundation
    /// had merely composed, so a stripped or partially-copied bundle yielded a
    /// URL to a file that wasn't there or wasn't runnable.
    static func resolve(in bundle: Bundle) -> URL? {
        let root = bundle.bundleURL
        let candidates: [URL?] = [
            root.appending(path: "Contents/MacOS/photodrop"),
            root.appending(path: "Contents/Helpers/photodrop"),
            // Layout-agnostic: whatever directory the bundle's own executable
            // lives in. Covers a flat bundle and any future rearrangement.
            bundle.executableURL?.deletingLastPathComponent().appending(path: "photodrop"),
            // Last, not first: correct when it answers, absent when it doesn't.
            bundle.url(forAuxiliaryExecutable: "photodrop"),
        ]
        return candidates.compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    /// Filesystem path of the bundled `photodrop`, ready for the launchd plist.
    static var path: String? { url?.path(percentEncoded: false) }
}
