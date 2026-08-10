import Foundation

struct DestinationFolder: Identifiable, Hashable, Sendable {
    let id: String         // e.g. "2026/2026-04-17"
    let year: Int
    let dayDate: Date
    let dayName: String    // "2026-04-17" or "2026-04-17_Wedding"
    let bundles: [AssetBundle]

    // Primaries-only count — useful for copies where only the RAW matters.
    var bundleCount: Int { bundles.count }
    // Total file count including every companion (.xmp / .dop / .pp3 /
    // jpeg pair / audio note) — what actually gets copied.
    var fileCount: Int { bundles.reduce(0) { $0 + $1.fileCount } }
    // Bytes across primaries and companions.
    var totalBytes: Int64 { bundles.reduce(0) { $0 + $1.totalSize } }
}

struct YearGroup: Identifiable, Hashable, Sendable {
    let id: Int
    let year: Int
    let folders: [DestinationFolder]

    // `totalFiles` intentionally includes companions so the preview
    // header matches the copy-work total. Use `bundleCount` if you need
    // primaries only.
    var totalFiles: Int { folders.reduce(0) { $0 + $1.fileCount } }
    var totalBytes: Int64 { folders.reduce(0) { $0 + $1.totalBytes } }
    var bundleCount: Int { folders.reduce(0) { $0 + $1.bundleCount } }
}

/// Counts for the *selected* subset of a plan.
///
/// The contact sheet lets the user deselect shots before ingest, and
/// `MainView.selectedYearGroups()` filters the plan accordingly — but every
/// count on screen was computed from the unfiltered plan. Deselect 400 of 500,
/// switch to the tree, and it read "500 files" beside a button that would copy
/// 100. One helper so the preview header, the detail subtitle and the ingest
/// button cannot drift apart again.
enum SelectionSummary {
    struct Counts: Equatable, Sendable {
        var files: Int
        var bytes: Int64
        var bundles: Int
    }

    static func of(yearGroups: [YearGroup], deselected: Set<AssetBundle.ID>) -> Counts {
        var counts = Counts(files: 0, bytes: 0, bundles: 0)
        for bundle in yearGroups.lazy.flatMap({ $0.folders }).flatMap(\.bundles)
        where !deselected.contains(bundle.id) {
            counts.files += bundle.fileCount
            counts.bytes += bundle.totalSize
            counts.bundles += 1
        }
        return counts
    }
}

enum PathPlanner {
    static func plan(bundles: [AssetBundle], description: String, template: NamingTemplate, cardLabel: String) -> [YearGroup] {
        guard !bundles.isEmpty else { return [] }

        let safeDescription = sanitize(description)
        let safeCardLabel = sanitize(cardLabel)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        // The day-folder a bundle lands in (relative to its year), per the
        // folder template — a "/" in the template nests subfolders. Joined with
        // "/" so it groups identically to CopyPlan.destinationDirectory's
        // components; the preview must agree with the copy.
        func leaf(for bundle: AssetBundle) -> String {
            let context = TemplateContext(
                date: bundle.primary.dateTaken,
                description: safeDescription,
                originalName: bundle.primary.url.lastPathComponent,
                originalStem: bundle.primary.url.deletingPathExtension().lastPathComponent,
                cardLabel: safeCardLabel
            )
            let components = sanitizedComponents(TemplateRenderer.render(template.folder, context))
            if !components.isEmpty { return components.joined(separator: "/") }
            let c = cal.dateComponents([.year, .month, .day], from: bundle.primary.dateTaken)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
        }

        // Group by (year, rendered leaf). The folder template defines the
        // grouping: the default day template groups by day, but e.g.
        // `{yyyy-MM}` groups by month. Year is always the top level.
        struct FolderKey: Hashable { let year: Int; let leaf: String }
        let grouped = Dictionary(grouping: bundles) { bundle -> FolderKey in
            FolderKey(year: cal.component(.year, from: bundle.primary.dateTaken), leaf: leaf(for: bundle))
        }

        let folders: [DestinationFolder] = grouped.map { key, dayBundles in
            // Representative date for sorting: the latest capture in the group.
            let dayDate = dayBundles.map(\.primary.dateTaken).max() ?? Date()
            return DestinationFolder(
                id: "\(key.year)/\(key.leaf)",
                year: key.year,
                dayDate: dayDate,
                dayName: key.leaf,
                bundles: dayBundles.sorted { $0.primary.dateTaken < $1.primary.dateTaken }
            )
        }

        // Group folders by year, newest first within year, newest year first.
        let byYear = Dictionary(grouping: folders, by: \.year)
        return byYear
            .map { year, yearFolders in
                YearGroup(
                    id: year,
                    year: year,
                    folders: yearFolders.sorted { $0.dayDate > $1.dayDate }
                )
            }
            .sorted { $0.year > $1.year }
    }

    /// Filesystem limit for a single path component, in UTF-8 bytes (APFS/HFS+
    /// cap a name at 255). A rendered component longer than this — e.g. a very
    /// long description or card label — would otherwise fail directory/file
    /// creation and abort the whole bundle, so we truncate to fit instead.
    static let maxComponentBytes = 255

    /// Characters replaced with `-` in any rendered path component.
    ///
    /// `/ \ :` are the POSIX/HFS-illegal set this always handled. The rest —
    /// `? * < > | "` — are legal on APFS and **rejected by SMB, exFAT and FAT**,
    /// which are precisely the filesystems N-way mirroring exists to write to. A
    /// description as ordinary as `Trip?` produced a folder the primary library
    /// accepted and every mirror refused at `mkdir`, surfacing to the user as
    /// "mirror 2: 500 failures" with nothing explaining why. A name has to be
    /// writable at *every* destination or the mirror silently stops being one.
    private static let illegalComponentCharacters: Set<Character> = ["/", "\\", ":", "?", "*", "<", ">", "|", "\""]

    // Light folder-name sanitization: strip whitespace, collapse spaces
    // to underscores, replace characters that can't sit in a path component on
    // any destination filesystem, neutralize "."/".."/hidden names, and cap the
    // length to what the filesystem allows.
    static func sanitize(_ s: String) -> String {
        var out = String(s.trimmingCharacters(in: .whitespacesAndNewlines).map {
            illegalComponentCharacters.contains($0) ? "-" : $0
        })
        out = out.replacingOccurrences(of: " ", with: "_")
        // Strip leading dots so a rendered component can never become "." or
        // ".." (a path-traversal / wrong-directory write) or a hidden entry.
        out = String(out.drop(while: { $0 == "." }))
        // Trailing dots are legal on APFS and silently stripped by SMB/exFAT —
        // same class as the characters above: the mirror ends up with a
        // differently-named folder than the library, so the two stop agreeing on
        // where a photo lives. Trailing spaces travel equally badly.
        out = String(out.reversed().drop(while: { $0 == "." || $0 == " " }).reversed())
        return truncatedToByteLimit(out, maxComponentBytes)
    }

    /// Splits a rendered folder template into one or more sanitized path
    /// components. A "/" in the *template* nests a subfolder (e.g.
    /// `{MM}/{yyyy-MM-dd}` → `["05", "2026-05-28"]`); each component is sanitized
    /// independently and empties — including `.`/`..`, which `sanitize` empties —
    /// are dropped. User data interpolated into the template is already
    /// slash-stripped by `sanitize` before interpolation, so it can't inject
    /// nesting; only the template author's literal "/" does.
    static func sanitizedComponents(_ rendered: String) -> [String] {
        rendered.split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitize(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Composes `stem` + `.` + `ext` so the **whole filename** fits in
    /// `maxComponentBytes`, truncating the stem as needed.
    ///
    /// `sanitize` caps the stem alone, which is the wrong boundary for a
    /// filename: a 255-byte stem plus `.CR2` is 259 bytes, and `open()` answers
    /// that with `ENAMETOOLONG` — failing the copy and rolling back the whole
    /// bundle over a name. A ~250-character name on a card is enough to reach it.
    /// The extension is never truncated; it is what makes the file openable.
    static func fileName(stem: String, extension ext: String) -> String {
        guard !ext.isEmpty else { return truncatedToByteLimit(stem, maxComponentBytes) }
        let room = maxComponentBytes - (ext.utf8.count + 1)   // +1 for the dot
        // A pathological extension leaves no room for a stem; keep at least the
        // extension so the result is still a usable name.
        guard room > 0 else { return truncatedToByteLimit(ext, maxComponentBytes) }
        return "\(truncatedToByteLimit(stem, room)).\(ext)"
    }

    /// Longest prefix of `s` that fits within `limit` UTF-8 bytes, truncated on a
    /// Character (grapheme) boundary so a multi-byte character is never split.
    static func truncatedToByteLimit(_ s: String, _ limit: Int) -> String {
        guard s.utf8.count > limit else { return s }
        var end = s.startIndex
        var bytes = 0
        for ch in s {
            let next = bytes + ch.utf8.count
            if next > limit { break }
            bytes = next
            end = s.index(after: end)
        }
        return String(s[s.startIndex..<end])
    }
}
