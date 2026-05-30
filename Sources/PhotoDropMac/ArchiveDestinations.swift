import Foundation

/// Assembles the ordered list of archive (mirror) destinations for an ingest:
/// the primary archive (if set), followed by any additional locations entered
/// one path per line. Pure, so it's unit-testable. Blank lines and surrounding
/// whitespace are ignored, and exact-duplicate paths are dropped (first wins) so
/// the same folder is never written twice in one job.
enum ArchiveDestinations {
    /// Newline-separated additional archive paths.
    static let extraDefaultsKey = "photodrop.extraArchiveDestinations"

    static func list(archive: String, extra: String) -> [URL] {
        var paths: [String] = []
        let primaryArchive = archive.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primaryArchive.isEmpty { paths.append(primaryArchive) }
        for line in extra.split(separator: "\n", omittingEmptySubsequences: true) {
            let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { paths.append(path) }
        }
        var seen = Set<String>()
        return paths.compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }
}
