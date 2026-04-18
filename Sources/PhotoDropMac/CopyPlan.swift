import Foundation

enum FileRole: Sendable, Hashable {
    case primary
    case companion(CompanionKind)
}

struct PlannedFile: Sendable, Hashable {
    let source: URL
    let destination: URL
    let size: Int64
    let role: FileRole
}

struct BundlePlan: Sendable, Hashable {
    let bundle: AssetBundle
    let files: [PlannedFile]   // primary at index 0

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

enum CopyPlan {
    // Path pattern (from Windows PhotoDrop):
    //   {root}/{yyyy}/{yyyy-MM-dd}[_{Description}]/{yyyyMMdd_HHmmss}_{OriginalName}
    //
    // Companions travel with their primary — their new names are derived
    // from the primary's new name so atomic renaming is preserved:
    //   - Long-form sidecar (IMG_1234.DNG.xmp) → {newPrimaryName}.xmp
    //   - Short-form sidecar (IMG_1234.xmp)    → {newPrimaryStem}.xmp
    //   - JPEG pair            (IMG_1234.JPG)  → {newPrimaryStem}.JPG
    static func plan(bundle: AssetBundle, destinationRoot: URL, description: String) -> BundlePlan {
        let primary = bundle.primary
        let primaryOldName = primary.url.lastPathComponent
        let primaryOldStem = primary.url.deletingPathExtension().lastPathComponent

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: primary.dateTaken)
        let year = c.year ?? 0
        let month = c.month ?? 1
        let day = c.day ?? 1
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        let second = c.second ?? 0

        let yyyymmdd = String(format: "%04d-%02d-%02d", year, month, day)
        let safeDescription = PathPlanner.sanitize(description)
        let dayFolder = safeDescription.isEmpty ? yyyymmdd : "\(yyyymmdd)_\(safeDescription)"
        let destDir = destinationRoot
            .appendingPathComponent(String(year), isDirectory: true)
            .appendingPathComponent(dayFolder, isDirectory: true)

        let timestamp = String(format: "%04d%02d%02d_%02d%02d%02d", year, month, day, hour, minute, second)
        let primaryNewName = "\(timestamp)_\(primaryOldName)"
        let primaryNewStem = "\(timestamp)_\(primaryOldStem)"
        let primaryDest = destDir.appendingPathComponent(primaryNewName)

        var files: [PlannedFile] = [
            PlannedFile(source: primary.url, destination: primaryDest, size: primary.size, role: .primary)
        ]

        for companion in bundle.companions {
            let companionOldName = companion.url.lastPathComponent
            let companionExt = (companionOldName as NSString).pathExtension
            let longPrefix = (primaryOldName + ".").lowercased()

            let newName: String
            if companionOldName.lowercased().hasPrefix(longPrefix) {
                // Long form: {primaryOldName}.{suffix} → {primaryNewName}.{suffix}
                let suffix = String(companionOldName.dropFirst(longPrefix.count))
                newName = "\(primaryNewName).\(suffix)"
            } else {
                // Short form: shared stem, different extension
                newName = "\(primaryNewStem).\(companionExt)"
            }

            files.append(PlannedFile(
                source: companion.url,
                destination: destDir.appendingPathComponent(newName),
                size: companion.size,
                role: .companion(companion.kind)
            ))
        }

        return BundlePlan(bundle: bundle, files: files)
    }
}
