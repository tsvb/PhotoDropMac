import Foundation

struct ScannedPhoto: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let size: Int64
    let dateTaken: Date
    let dateSource: DateSource

    enum DateSource: Sendable {
        case exif
        case fileModification
    }
}

// RAW extensions PhotoDrop treats as first-class primaries. Matches the
// Windows `AssetDiscoveryService.RawExtensions` set exactly.
private let rawExtensions: Set<String> = [
    "dng", "raf", "arw", "cr2", "cr3", "nef", "nrw", "orf", "rw2",
    "pef", "srw", "3fr", "rwl", "x3f", "erf", "mrw", "mef",
    "iiq", "raw", "sr2", "srf", "dcr", "kdc", "mos",
]

// JPEG extensions. A JPEG is either a companion (when a same-stem RAW
// lives in the same directory) or a primary bundle of its own.
private let jpegExtensions: Set<String> = ["jpg", "jpeg"]

// Recognised sidecar extensions. `.wav` only counts when it shares its
// stem with a primary — it's treated as a camera audio note.
private let sidecarExtensions: Set<String> = ["dop", "xmp", "pp3", "wav"]

// Accepted primary extensions (RAW + JPEG). Anything else is ignored at
// the enumeration stage, matching the Windows reference.
private let primaryExtensions: Set<String> = rawExtensions.union(jpegExtensions)

// Every extension the enumerator needs to surface. Filtering by this
// set up front keeps scratch files (`.tmp`, `.ctg`, etc.) out of the
// in-memory sibling list.
private let recognisedExtensions: Set<String> = primaryExtensions.union(sidecarExtensions)

// One enumerator row after it's been classified. We hold these per
// directory so the two-pass algorithm can run over a single group's
// worth of siblings at a time.
private struct FileEntry {
    let url: URL
    let size: Int64
    let modDate: Date
    let name: String
    let stem: String
    let ext: String
}

enum AssetDiscovery {
    // Two-pass discovery, per the Windows `AssetDiscoveryService`:
    //   1. RAW primaries and their same-directory companions.
    //   2. Standalone JPEGs — JPEGs not already claimed as a JpegPair
    //      companion by a RAW in the same directory.
    // Orphan sidecars (a .dop with no primary) are silently dropped.
    static func scan(root: URL) -> [AssetBundle] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        // All files that could matter (primary or sidecar), grouped by
        // their parent directory. Same-directory grouping is how the
        // same-directory rule is enforced: we only ever classify
        // siblings inside a single group.
        var byDirectory: [URL: [FileEntry]] = [:]

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard recognisedExtensions.contains(ext) else { continue }
            let size = Int64(values.fileSize ?? 0)
            let modDate = values.contentModificationDate ?? Date()
            let name = url.lastPathComponent
            let stem = url.deletingPathExtension().lastPathComponent
            let parent = url.deletingLastPathComponent()
            let entry = FileEntry(url: url, size: size, modDate: modDate, name: name, stem: stem, ext: ext)
            byDirectory[parent, default: []].append(entry)
        }

        var bundles: [AssetBundle] = []
        var consumed: Set<URL> = []

        // Stable directory order keeps the output deterministic even if
        // the enumerator visits directories in filesystem order.
        let sortedDirs = byDirectory.keys.sorted { $0.path < $1.path }
        for dir in sortedDirs {
            guard let siblings = byDirectory[dir] else { continue }

            // Pass 1: RAW primaries.
            for file in siblings where rawExtensions.contains(file.ext) {
                if consumed.contains(file.url) { continue }
                let bundle = buildBundle(primary: file, siblings: siblings)
                consumed.insert(file.url)
                for c in bundle.companions { consumed.insert(c.url) }
                bundles.append(bundle)
            }

            // Pass 2: standalone JPEGs (those not consumed as a
            // JpegPair companion during pass 1).
            for file in siblings where jpegExtensions.contains(file.ext) {
                if consumed.contains(file.url) { continue }
                let bundle = buildBundle(primary: file, siblings: siblings)
                consumed.insert(file.url)
                for c in bundle.companions { consumed.insert(c.url) }
                bundles.append(bundle)
            }
        }

        return bundles
    }

    // Build a bundle for `primary`, pulling every sibling that
    // classifies as a companion. `siblings` is already scoped to the
    // primary's own directory.
    private static func buildBundle(
        primary: FileEntry,
        siblings: [FileEntry]
    ) -> AssetBundle {
        let photo = makeScannedPhoto(from: primary)

        var companions: [CompanionFile] = []
        for sibling in siblings {
            if sibling.url == primary.url { continue }
            guard let kind = classifyCompanion(
                neighborName: sibling.name,
                neighborExt: sibling.ext,
                primaryStem: primary.stem,
                primaryName: primary.name
            ) else { continue }
            companions.append(CompanionFile(url: sibling.url, size: sibling.size, kind: kind))
        }

        return AssetBundle(primary: photo, companions: companions)
    }

    // Decide whether `neighbor` is a companion of the primary. Two
    // shapes are accepted, matching the Windows `TryClassifyCompanion`:
    //
    //   A. `<primaryName>.<ext>` — neighbour starts with the primary's
    //      full filename and appends a sidecar extension. Covers the
    //      Adobe-style `IMG_1234.DNG.xmp` and the DxO `IMG_1234.DNG.dop`
    //      variants. Sidecar extensions only.
    //
    //   B. `<primaryStem>.<ext>` — neighbour shares the primary's stem
    //      but has a different extension. Covers the short-form xmp
    //      (`IMG_1234.xmp`), JPEG pairs (`IMG_1234.JPG`), and camera
    //      audio notes (`IMG_1234.WAV`). Sidecar or JPEG extensions.
    //
    // All comparisons are case-insensitive so `.DNG` and `.dng` behave
    // identically.
    private static func classifyCompanion(
        neighborName: String,
        neighborExt: String,
        primaryStem: String,
        primaryName: String
    ) -> CompanionKind? {
        let neighborLower = neighborName.lowercased()

        // Case A — <primaryName>.<sidecarExt>.
        let longPrefix = (primaryName + ".").lowercased()
        if neighborLower.hasPrefix(longPrefix), sidecarExtensions.contains(neighborExt) {
            return kind(forExtension: neighborExt)
        }

        // Case B — <primaryStem>.<ext>, where ext is sidecar or jpeg.
        let stemPrefix = (primaryStem + ".").lowercased()
        if neighborLower.hasPrefix(stemPrefix),
           sidecarExtensions.contains(neighborExt) || jpegExtensions.contains(neighborExt)
        {
            return kind(forExtension: neighborExt)
        }

        return nil
    }

    private static func kind(forExtension ext: String) -> CompanionKind? {
        switch ext {
        case "dop": return .dop
        case "xmp": return .xmp
        case "pp3": return .pp3
        case "jpg", "jpeg": return .jpegPair
        case "wav": return .audioNote
        default: return nil
        }
    }

    private static func makeScannedPhoto(from file: FileEntry) -> ScannedPhoto {
        let date: Date
        let source: ScannedPhoto.DateSource
        if let exifDate = ExifReader.dateTaken(for: file.url) {
            date = exifDate
            source = .exif
        } else {
            date = file.modDate
            source = .fileModification
        }
        return ScannedPhoto(
            id: file.url,
            url: file.url,
            size: file.size,
            dateTaken: date,
            dateSource: source
        )
    }
}
