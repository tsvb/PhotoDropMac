import Foundation

struct DestinationFolder: Identifiable, Hashable, Sendable {
    let id: String         // e.g. "2026/2026-04-17"
    let year: Int
    let dayDate: Date
    let dayName: String    // "2026-04-17" or "2026-04-17_Wedding"
    let photos: [ScannedPhoto]

    var fileCount: Int { photos.count }
    var totalBytes: Int64 { photos.reduce(0) { $0 + $1.size } }
}

struct YearGroup: Identifiable, Hashable, Sendable {
    let id: Int
    let year: Int
    let folders: [DestinationFolder]

    var totalFiles: Int { folders.reduce(0) { $0 + $1.fileCount } }
    var totalBytes: Int64 { folders.reduce(0) { $0 + $1.totalBytes } }
}

enum PathPlanner {
    static func plan(photos: [ScannedPhoto], description: String) -> [YearGroup] {
        guard !photos.isEmpty else { return [] }

        let safeDescription = sanitize(description)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        // Group photos by (year, month, day)
        struct DayKey: Hashable { let year: Int; let month: Int; let day: Int }
        let grouped = Dictionary(grouping: photos) { photo -> DayKey in
            let c = cal.dateComponents([.year, .month, .day], from: photo.dateTaken)
            return DayKey(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
        }

        // Turn each day group into a DestinationFolder
        let folders: [DestinationFolder] = grouped.compactMap { key, dayPhotos in
            let dayDate = cal.date(from: DateComponents(year: key.year, month: key.month, day: key.day)) ?? Date()
            let dateString = String(format: "%04d-%02d-%02d", key.year, key.month, key.day)
            let dayName = safeDescription.isEmpty ? dateString : "\(dateString)_\(safeDescription)"
            return DestinationFolder(
                id: "\(key.year)/\(dateString)",
                year: key.year,
                dayDate: dayDate,
                dayName: dayName,
                photos: dayPhotos.sorted { $0.dateTaken < $1.dateTaken }
            )
        }

        // Group folders by year, newest first within year, newest year first
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
