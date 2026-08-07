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
    // Path: {root}/{yyyy}/{folder-template}/{filename-template}.{ext}. The
    // folder (day-folder leaf) and filename (primary stem) are user-configurable
    // via NamingTemplate; the year is always the fixed top level. The default
    // templates reproduce PhotoDrop's established pattern:
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
        template: NamingTemplate,
        cardLabel: String,
        existingPaths: Set<String> = []
    ) -> [BundlePlan] {
        var taken = existingPaths
        var plans: [BundlePlan] = []
        plans.reserveCapacity(bundles.count)
        for bundle in bundles {
            let bundlePlan = plan(bundle: bundle, destinationRoot: destinationRoot, description: description, template: template, cardLabel: cardLabel) { url in
                taken.contains(url.path)
            }
            for file in bundlePlan.files { taken.insert(file.destination.path) }
            plans.append(bundlePlan)
        }
        return plans
    }

    /// The day-folder a bundle's files land in: `{root}/{yyyy}/{yyyy-MM-dd}[_{desc}]`.
    /// Shared by `plan` and by the collision scan so both agree on exactly
    /// which directory a job writes into.
    static func destinationDirectory(for bundle: AssetBundle, destinationRoot: URL, description: String, template: NamingTemplate, cardLabel: String) -> URL {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let date = bundle.primary.dateTaken
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let year = c.year ?? 0

        let context = TemplateContext(
            date: date,
            description: PathPlanner.sanitize(description),
            originalName: bundle.primary.url.lastPathComponent,
            originalStem: bundle.primary.url.deletingPathExtension().lastPathComponent,
            cardLabel: PathPlanner.sanitize(cardLabel)
        )
        // A "/" in the folder template nests subfolders below the (fixed) year.
        let components = PathPlanner.sanitizedComponents(TemplateRenderer.render(template.folder, context))
        // Never produce a nameless folder — fall back to the ISO date if the
        // template renders nothing usable.
        let safeComponents = components.isEmpty
            ? [String(format: "%04d-%02d-%02d", year, c.month ?? 1, c.day ?? 1)]
            : components

        var dir = destinationRoot.appendingPathComponent(String(year), isDirectory: true)
        for component in safeComponents {
            dir = dir.appendingPathComponent(component, isDirectory: true)
        }
        return dir
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
        template: NamingTemplate,
        cardLabel: String,
        isTaken: (URL) -> Bool = { _ in false }
    ) -> BundlePlan {
        let primary = bundle.primary
        let primaryOldName = primary.url.lastPathComponent
        let primaryOldStem = primary.url.deletingPathExtension().lastPathComponent
        let primaryExt = primary.url.pathExtension

        let destDir = destinationDirectory(for: bundle, destinationRoot: destinationRoot, description: description, template: template, cardLabel: cardLabel)

        let context = TemplateContext(
            date: primary.dateTaken,
            description: PathPlanner.sanitize(description),
            originalName: primaryOldName,
            originalStem: primaryOldStem,
            cardLabel: PathPlanner.sanitize(cardLabel)
        )
        let renderedStem = PathPlanner.sanitize(TemplateRenderer.render(template.filename, context))
        let baseStem = renderedStem.isEmpty ? fallbackStem(date: primary.dateTaken, stem: primaryOldStem) : renderedStem

        // Smallest disambiguator (0 = none) that frees every file in the bundle.
        // `taken` is a finite set (on-disk + already-claimed), so some `n` is
        // always free; this terminates.
        var n = 0
        while true {
            let disambiguator = n == 0 ? "" : "_\(n)"
            // The disambiguator and the extension both have to fit inside
            // NAME_MAX alongside the stem, so the stem is trimmed against what
            // they need rather than capped on its own — see PathPlanner.fileName.
            let stemRoom = PathPlanner.maxComponentBytes
                - disambiguator.utf8.count
                - (primaryExt.isEmpty ? 0 : primaryExt.utf8.count + 1)
            let primaryNewStem = PathPlanner.truncatedToByteLimit(baseStem, max(1, stemRoom)) + disambiguator
            let primaryNewName = PathPlanner.fileName(stem: primaryNewStem, extension: primaryExt)
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

    // Default stem when a filename template renders empty: the canonical
    // {yyyyMMdd_HHmmss}_{OriginalStem}, so a blank template never strands files.
    private static func fallbackStem(date: Date, stem: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let ts = String(format: "%04d%02d%02d_%02d%02d%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "\(ts)_\(stem)"
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

            // Both forms go through `PathPlanner.fileName`, so a companion can't
            // push past NAME_MAX and fail the bundle either. In the pathological
            // case of a near-maximum primary name the companion's stem is trimmed
            // a little further than the primary's; a copy that lands with a
            // slightly shorter stem beats a bundle that fails to copy at all.
            let newName: String
            if companionOldName.lowercased().hasPrefix(longPrefix) {
                // Long form: {primaryOldName}.{suffix} → {primaryNewName}.{suffix}
                let suffix = String(companionOldName.dropFirst(longPrefix.count))
                newName = PathPlanner.fileName(stem: primaryNewName, extension: suffix)
            } else {
                // Short form: shared stem, different extension
                newName = PathPlanner.fileName(stem: primaryNewStem, extension: companionExt)
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
