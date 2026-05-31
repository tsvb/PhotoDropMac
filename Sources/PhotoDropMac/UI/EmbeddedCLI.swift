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
    static var url: URL? {
        if let u = Bundle.main.url(forAuxiliaryExecutable: "photodrop") { return u }
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/photodrop")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    /// Filesystem path of the bundled `photodrop`, ready for the launchd plist.
    static var path: String? { url?.path(percentEncoded: false) }
}
