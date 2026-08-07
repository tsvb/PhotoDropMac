import Foundation

/// Validates the *relationships between* the trees an ingest touches — source vs
/// destination, and destination vs destination.
///
/// Every other guard in this app protects one tree in isolation.
/// `ArchiveDestinations.dedupedRoots` compares device + inode, so it catches "the
/// same folder listed twice" and nothing else, and `DestinationIndex.findDuplicate`
/// deliberately matches content *anywhere under a destination root*. Those two
/// facts compose badly when the trees overlap, and nothing checked:
///
/// - **A destination that contains the source.** Every source file is indexed as
///   an existing destination file and matches **itself** — same size, same
///   digest. Measured: `filesCopied == 0`, `filesFailed == 0`, `haltReason == nil`,
///   every file logged `already present as <its own name>`, and a manifest whose
///   entries point at the *source* files. The job reports success, the CLI exits
///   0, and the app then ejects the card (the eject is gated on halt/cancel, not
///   on anything having been copied). The user is told "Ingest complete" and
///   holds a card that was never copied.
/// - **A mirror root that contains the primary** (`archive = /Vol/X`,
///   `primary = /Vol/X/Lib`). From the second run onward the mirror's index walks
///   into `Lib/` and finds the primary's own copies, so every mirror write is
///   skipped as an ordinary duplicate. Add a parent folder as a mirror to an
///   existing library and the mirror stays **empty forever**, reporting success
///   every time: two copies on paper, one on disk.
/// - **A mirror root inside the primary** (`archive = /Vol/X/Lib/Backup`). Cull a
///   day-folder from the library, re-ingest the card, and the *primary* write is
///   skipped in favour of the surviving copy under `Backup/` — which the manifest
///   then records as `Backup/2024/IMG_0001.CR2`. That path resolves cleanly under
///   the library root, so `verify` calls the library healthy while the library
///   proper is missing the photo.
///
/// None of these are recoverable after the fact, and all three read as success,
/// so the job is **refused** rather than warned about. Equal roots are not a
/// problem here — `dedupedRoots` already collapses them, which is the correct
/// handling for that case.
enum DestinationTopology {
    enum Problem: Sendable, Equatable {
        case sourceInsideDestination(source: URL, destination: URL)
        case destinationInsideSource(destination: URL, source: URL)
        case nestedDestinations(outer: URL, inner: URL)

        /// One clause, for `haltReason` and the UI's single-sentence halt line.
        var shortReason: String {
            switch self {
            case .sourceInsideDestination:  return "the source is inside a destination folder"
            case .destinationInsideSource:  return "a destination folder is inside the source"
            case .nestedDestinations:       return "one destination folder is inside another"
            }
        }

        var message: String {
            switch self {
            case let .sourceInsideDestination(source, destination):
                return "The source “\(source.path(percentEncoded: false))” is inside the destination "
                     + "“\(destination.path(percentEncoded: false))”. Every file would be detected as a "
                     + "duplicate of itself, so nothing would be copied and the job would report success."
            case let .destinationInsideSource(destination, source):
                return "The destination “\(destination.path(percentEncoded: false))” is inside the source "
                     + "“\(source.path(percentEncoded: false))”. The ingest would copy into the folder it is "
                     + "reading from."
            case let .nestedDestinations(outer, inner):
                return "Destination “\(inner.path(percentEncoded: false))” is inside destination "
                     + "“\(outer.path(percentEncoded: false))”. They are not independent copies: one would "
                     + "detect the other’s files as duplicates and silently stop being written."
            }
        }
    }

    /// Every overlap among the source and the destination roots, in a stable
    /// order. Empty means the topology is safe.
    static func check(source: URL?, roots: [URL]) -> [Problem] {
        var problems: [Problem] = []

        if let source {
            for root in roots {
                if contains(root, source) {
                    problems.append(.sourceInsideDestination(source: source, destination: root))
                } else if contains(source, root) {
                    problems.append(.destinationInsideSource(destination: root, source: source))
                }
            }
        }

        for (i, outer) in roots.enumerated() {
            for inner in roots[(i + 1)...] {
                if contains(outer, inner) {
                    problems.append(.nestedDestinations(outer: outer, inner: inner))
                } else if contains(inner, outer) {
                    problems.append(.nestedDestinations(outer: inner, inner: outer))
                }
            }
        }
        return problems
    }

    /// True when `inner` is **strictly** below `outer`.
    ///
    /// Compares path *components*, not string prefixes: `/Vol/Library2` is not
    /// inside `/Vol/Library`, but a raw `hasPrefix` says it is. Symlinks are
    /// resolved first for the same reason `ArchiveDestinations.identity` resolves
    /// them — these are user-typed configuration paths checked against a live
    /// filesystem, where a symlinked mirror really does name the same tree. (This
    /// is a different check from `ManifestWriter.resolve`, which stays lexical
    /// because it validates *untrusted* manifest paths and must behave identically
    /// for files that exist and files that don't.)
    static func contains(_ outer: URL, _ inner: URL) -> Bool {
        let a = components(of: outer)
        let b = components(of: inner)
        guard b.count > a.count else { return false }
        return Array(b.prefix(a.count)) == a
    }

    /// Path components in a shape that is the **same whether or not the path
    /// exists**.
    ///
    /// `resolvingSymlinksInPath()` consults the filesystem, so it rewrites
    /// `/private/tmp/x` to `/tmp/x` for a directory that exists and leaves it
    /// alone for one that doesn't. Comparing a resolved path against an
    /// unresolved one then finds no common prefix and the overlap goes
    /// undetected. Measured: `heal --script <lib>/evil.sh` wrote the script
    /// straight into the library, because the library existed and the script
    /// path did not — and, far worse, a nested *archive root that has not been
    /// created yet* was not detected as nested, which is precisely the
    /// configuration `ArchiveDestinations.identity` documents as routine (an
    /// unplugged drive, a folder the job will create).
    ///
    /// So: resolve symlinks on the deepest ancestor that does exist, then
    /// re-append the components that don't. Two paths sharing an existing
    /// ancestor now always agree on how that ancestor is spelled.
    private static func components(of url: URL) -> [String] {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: url.path(percentEncoded: false)).standardizedFileURL
        var trailing: [String] = []

        while !fm.fileExists(atPath: probe.path(percentEncoded: false)) {
            let parent = probe.deletingLastPathComponent()
            // Guard against a path that never resolves to an existing ancestor;
            // at the filesystem root, deletingLastPathComponent is a fixed point.
            if parent.path(percentEncoded: false) == probe.path(percentEncoded: false) { break }
            trailing.insert(probe.lastPathComponent, at: 0)
            probe = parent
        }

        let existing = probe.resolvingSymlinksInPath().pathComponents.filter { $0 != "/" && $0 != "." }
        return existing + trailing
    }
}
