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
    //
    // Two source files whose capture-second *and* original filename collide
    // (e.g. IMG_0001.JPG from two DCIM folders shot in the same second) would
    // otherwise plan onto the same destination path and silently overwrite
    // each other. To prevent that, `planBatch` threads a set of already-claimed
    // paths through every bundle, and `plan` appends a `_1`, `_2`, …
    // disambiguator to the primary's stem (with companions following) until the
    // whole bundle lands on free paths.

    /// Plan a batch of bundles against one destination root, guaranteeing that
    /// no two planned files — and no planned file vs. a path already present at
    /// the destination (`existingPaths`) — share a destination path.
    static func planBatch(
        bundles: [AssetBundle],
        destinationRoot: URL,
        description: String,
        existingPaths: Set<String> = []
    ) -> [BundlePlan] {
        var taken = existingPaths
        var plans: [BundlePlan] = []
        plans.reserveCapacity(bundles.count)
        for bundle in bundles {
            let bundlePlan = plan(bundle: bundle, destinationRoot: destinationRoot, description: description) { url in
                taken.contains(url.path)
            }
            for file in bundlePlan.files { taken.insert(file.destination.path) }
            plans.append(bundlePlan)
        }
        return plans
    }

    /// Plan a single bundle. `isTaken` reports whether a candidate destination
    /// path is already spoken for; when any file in the bundle would land on a
    /// taken path, the primary's stem gets a numeric suffix and the whole
    /// bundle is re-derived until every file is free. The default predicate
    /// (nothing taken) yields the bare, suffix-free names.
    static func plan(
        bundle: AssetBundle,
        destinationRoot: URL,
        description: String,
        isTaken: (URL) -> Bool = { _ in false }
    ) -> BundlePlan {
        let primary = bundle.primary
        let primaryOldName = primary.url.lastPathComponent
        let primaryOldStem = primary.url.deletingPathExtension().lastPathComponent
        let primaryExt = primary.url.pathExtension

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
        let baseStem = "\(timestamp)_\(primaryOldStem)"

        // Smallest disambiguator (0 = none) that frees every file in the bundle.
        // `taken` is a finite set (on-disk + already-claimed), so some `n` is
        // always free; this terminates.
        var n = 0
        while true {
            let disambiguator = n == 0 ? "" : "_\(n)"
            let primaryNewStem = baseStem + disambiguator
            let primaryNewName = primaryExt.isEmpty ? primaryNewStem : "\(primaryNewStem).\(primaryExt)"
            let files = buildFiles(
                bundle: bundle,
                primaryOldName: primaryOldName,
                primaryNewName: primaryNewName,
                primaryNewStem: primaryNewStem,
                destDir: destDir
            )
            if !files.contains(where: { isTaken($0.destination) }) {
                return BundlePlan(bundle: bundle, files: files)
            }
            n += 1
        }
    }

    // Build the bundle's planned files for a given resolved primary name/stem.
    // Companion names are always derived from the primary's resolved name, so a
    // disambiguated primary carries its companions with it.
    private static func buildFiles(
        bundle: AssetBundle,
        primaryOldName: String,
        primaryNewName: String,
        primaryNewStem: String,
        destDir: URL
    ) -> [PlannedFile] {
        var files: [PlannedFile] = [
            PlannedFile(
                source: bundle.primary.url,
                destination: destDir.appendingPathComponent(primaryNewName),
                size: bundle.primary.size,
                role: .primary
            )
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

        return files
    }
}
