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

    /// The lookup, with the bundle injected so it is testable. Both branches are
    /// held to the same standard — `isExecutableFile` — because the primary
    /// branch was not: `url(forAuxiliaryExecutable:)` returns a URL for a path it
    /// merely *constructed*, so a stripped or partially-copied bundle yielded a
    /// path to a file that isn't there, or isn't runnable. That path then went
    /// into the launchd plist as `MaintenancePreferences`' default, where the
    /// failure mode is a scheduled verification that silently never runs — the
    /// worst possible place for an unchecked path, since the whole point of the
    /// nightly job is to tell you when something is wrong.
    static func resolve(in bundle: Bundle) -> URL? {
        let candidates = [
            bundle.url(forAuxiliaryExecutable: "photodrop"),
            bundle.bundleURL.appending(path: "Contents/Helpers/photodrop"),
        ]
        return candidates.compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    /// Filesystem path of the bundled `photodrop`, ready for the launchd plist.
    static var path: String? { url?.path(percentEncoded: false) }
}
