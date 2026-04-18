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

// Primary photo extensions PhotoDrop recognizes. Mirrors the Windows
// PhotoDrop.Core AssetDiscoveryService set plus modern HEIC/HEIF.
private let primaryExtensions: Set<String> = [
    // RAW
    "dng", "raf", "arw", "cr2", "cr3", "nef", "nrw", "orf", "rw2",
    "pef", "srw", "3fr", "rwl", "x3f", "erf", "mrw", "mef", "iiq",
    "raw", "sr2", "srf", "dcr", "kdc", "mos",
    // JPEG
    "jpg", "jpeg",
    // Modern
    "heic", "heif",
    // Occasional
    "tif", "tiff",
]

enum AssetDiscovery {
    static func scan(root: URL) -> [ScannedPhoto] {
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

        var photos: [ScannedPhoto] = []
        photos.reserveCapacity(1024)

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard primaryExtensions.contains(ext) else { continue }

            let size = Int64(values.fileSize ?? 0)
            let modDate = values.contentModificationDate ?? Date()

            let date: Date
            let source: ScannedPhoto.DateSource
            if let exifDate = ExifReader.dateTaken(for: url) {
                date = exifDate
                source = .exif
            } else {
                date = modDate
                source = .fileModification
            }

            photos.append(ScannedPhoto(
                id: url,
                url: url,
                size: size,
                dateTaken: date,
                dateSource: source
            ))
        }

        return photos
    }
}
