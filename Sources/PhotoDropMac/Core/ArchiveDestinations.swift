import Foundation

/// Assembles the ordered list of archive (mirror) destinations for an ingest:
/// the primary archive (if set), followed by any additional locations entered
/// one path per line. Pure, so it's unit-testable. Blank lines and surrounding
/// whitespace are ignored.
///
/// **Duplicates are dropped by filesystem identity, including against the
/// primary destination.** Two pickers side by side make "archive = primary" an
/// easy mistake, and writing one root twice is not a harmless no-op: pass 2
/// finds pass 1's file already there, `FileCopier`'s `O_EXCL` correctly refuses
/// to overwrite it, and the resulting `.destinationExists` is counted as a
/// failed bundle. A completely successful ingest then reports *every* bundle
/// failed. Comparing raw strings is not enough for the same reason — `/x/` and
/// `/x`, a symlink and its target, or two mount paths for one volume are the
/// same folder to the filesystem and to `O_EXCL`, but different strings.
enum ArchiveDestinations {
    /// Newline-separated additional archive paths.
    static let extraDefaultsKey = "photodrop.extraArchiveDestinations"

    /// The mirror list from the two settings fields, excluding the primary.
    static func list(primary: String, archive: String, extra: String) -> [URL] {
        var candidates: [String] = [archive]
        candidates += extra.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return mirrors(primary: primary, candidates: candidates)
    }

    /// Dedupe an explicit, ordered list of mirror paths against each other and
    /// against the primary (first spelling of a given folder wins). Shared by the
    /// settings path and the CLI's repeatable `--archive`, so both get the same
    /// protection.
    static func mirrors(primary: String, candidates: [String]) -> [URL] {
        var seen = Set<String>()
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrimary.isEmpty { seen.insert(identity(ofPath: trimmedPrimary)) }

        return candidates.compactMap { candidate in
            let path = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(identity(ofPath: path)).inserted else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// Collapse an ordered list of destination roots to the distinct folders
    /// among them, first spelling winning. The engine calls this on
    /// `[primary] + archives` as a last line of defence: the settings and CLI
    /// paths above already dedupe, but the engine takes roots from any caller
    /// and one folder listed twice turns a clean ingest into a reported total
    /// failure — too sharp an edge to leave to callers.
    static func dedupedRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        return roots.filter { seen.insert(identity(ofPath: $0.path(percentEncoded: false))).inserted }
    }

    /// A key that is equal for two paths naming the same directory.
    ///
    /// Uses device + inode when the path exists, which is what makes a symlink,
    /// a second mount of one volume, and a `/x/` vs `/x` spelling all collapse to
    /// one destination. Archive folders are routinely configured before they
    /// exist (an unplugged drive, a folder the job will create), so a
    /// non-existent path falls back to its symlink-resolved, standardized form —
    /// that still catches the trailing-slash and `..` spellings, and two paths
    /// that only turn out to be the same folder once both exist are caught on the
    /// next run, when they do.
    static func identity(ofPath path: String) -> String {
        var info = stat()
        if stat(path, &info) == 0 {
            return "dev:\(info.st_dev)/ino:\(info.st_ino)"
        }
        return URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }
}
