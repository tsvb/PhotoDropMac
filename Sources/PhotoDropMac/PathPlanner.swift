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

enum PathPlanner {
    static func plan(bundles: [AssetBundle], description: String, template: NamingTemplate, cardLabel: String) -> [YearGroup] {
        guard !bundles.isEmpty else { return [] }

        let safeDescription = sanitize(description)
        let safeCardLabel = sanitize(cardLabel)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        // The day-folder leaf a bundle lands in, per the folder template. Must
        // match CopyPlan.destinationDirectory's leaf for the preview to agree
        // with the copy.
        func leaf(for bundle: AssetBundle) -> String {
            let context = TemplateContext(
                date: bundle.primary.dateTaken,
                description: safeDescription,
                originalName: bundle.primary.url.lastPathComponent,
                originalStem: bundle.primary.url.deletingPathExtension().lastPathComponent,
                cardLabel: safeCardLabel
            )
            let rendered = sanitize(TemplateRenderer.render(template.folder, context))
            if !rendered.isEmpty { return rendered }
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

    // Light folder-name sanitization: strip whitespace, collapse spaces
    // to underscores, and replace characters that can't sit in a POSIX
    // path component.
    static func sanitize(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.replacingOccurrences(of: "/", with: "-")
        out = out.replacingOccurrences(of: "\\", with: "-")
        out = out.replacingOccurrences(of: ":", with: "-")
        out = out.replacingOccurrences(of: " ", with: "_")
        return out
    }
}
