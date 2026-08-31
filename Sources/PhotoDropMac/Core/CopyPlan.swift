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
    /// The `_n` suffix this bundle settled on (0 = none). Carried so `planBatch`
    /// can start the next bundle with the same base name from here instead of
    /// counting up from zero — see the O(n²) note there.
    let disambiguator: Int

    init(bundle: AssetBundle, files: [PlannedFile], disambiguator: Int = 0) {
        self.bundle = bundle
        self.files = files
        self.disambiguator = disambiguator
    }

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
        var taken = Set(existingPaths.map(collisionKey))
        var plans: [BundlePlan] = []
        plans.reserveCapacity(bundles.count)

        // Remember the disambiguator each base name reached, so the next bundle
        // with that name resumes from there instead of counting up from zero.
        //
        // Without it `plan` restarts at n = 0 every time, so with a filename
        // template that has no per-file component — `{yyyy-MM-dd}`, or
        // `{HHmmss}` on burst frames, both of which the Settings legend
        // advertises — bundle *k* does *k* iterations and planning is O(n²).
        // Measured: 800 bundles rendering to one name took 1.95 s. The hint is
        // only a starting point; `plan` still verifies every candidate against
        // `isTaken`, so a wrong hint costs iterations, never a collision.
        var nextDisambiguator: [String: Int] = [:]
        var sequence = 0

        for bundle in bundles {
            // Keyed on the *rendered base name inside its day-folder* — the thing
            // that actually collides. Keying on the folder alone would make
            // distinct names inherit each other's suffixes.
            // 1-based position in the batch, for `{Sequence}`. Stable across the
            // mirrors because `IngestEngine.rebase` reuses these very plans, and
            // stable against the preview because the folder template never sees a
            // sequence — see `destinationDirectory`.
            sequence += 1
            let hintKey = collisionKey(
                destinationDirectory(for: bundle, destinationRoot: destinationRoot,
                                     description: description, template: template,
                                     cardLabel: cardLabel).path
                + "\u{0}"
                + baseStem(for: bundle, description: description, template: template,
                           cardLabel: cardLabel, sequence: sequence))
            let bundlePlan = plan(
                bundle: bundle, destinationRoot: destinationRoot, description: description,
                template: template, cardLabel: cardLabel,
                startingAt: nextDisambiguator[hintKey] ?? 0,
                sequence: sequence
            ) { url in
                taken.contains(collisionKey(url.path))
            }
            for file in bundlePlan.files { taken.insert(collisionKey(file.destination.path)) }
            nextDisambiguator[hintKey] = bundlePlan.disambiguator + 1
            plans.append(bundlePlan)
        }
        return plans
    }

    /// The key two destination paths are compared on when deciding whether a name
    /// is free.
    ///
    /// **Case-folded, because APFS is case-insensitive by default.** Comparing raw
    /// strings meant `IMG_0001.JPG` and `img_0001.jpg` — the same file on disk —
    /// looked like two free names, so `_1` never fired, `FileCopier`'s `O_EXCL`
    /// correctly refused the second write, and that bundle failed and rolled back
    /// on *every* run, forever: a photo the user believes was ingested never is.
    /// Two DCIM folders shot in the same second, or the far more common `.JPG` vs
    /// `.jpg` extension casing against a name already on disk, both reach it.
    ///
    /// Folded **unconditionally** rather than probing each volume's case
    /// sensitivity: the whole point of the union rule in `IngestEngine` is that a
    /// name is free only if it is free at *every* destination, so one
    /// case-insensitive mirror in the set would make folding mandatory anyway. The
    /// cost on an all-case-sensitive setup is an occasional unnecessary `_1` —
    /// a cosmetic name, never a lost or overwritten file.
    ///
    /// Canonical (NFC) mapping is applied for the same reason at the Unicode
    /// level; Swift's own `String` comparison already normalizes, but `lowercased`
    /// on a decomposed string is not guaranteed to yield the same scalars as on a
    /// composed one, and this key is compared as a raw `String` in a `Set`.
    static func collisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
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

        // **No sequence here, deliberately.** `PathPlanner.plan` renders this same
        // folder template to group the preview tree, and the two must agree — the
        // doc calls a preview that shows one tree while the bytes go to another
        // the exact dishonesty this app exists not to commit. A sequence number
        // cannot agree across them: the preview is planned over every bundle on
        // the card, while the copy runs over the *selected* ones, so a cull would
        // shift every folder name. `{Sequence}` therefore renders empty in a
        // folder template (dropping its optional group) and is a filename token.
        let context = TemplateContext(
            date: date,
            description: PathPlanner.sanitize(description),
            originalName: bundle.primary.url.lastPathComponent,
            originalStem: bundle.primary.url.deletingPathExtension().lastPathComponent,
            cardLabel: PathPlanner.sanitize(cardLabel),
            cameraModel: PathPlanner.sanitize(bundle.primary.cameraModel),
            bodySerial: PathPlanner.sanitize(bundle.primary.bodySerial)
        )
        // A "/" in the folder template nests subfolders below the year — and
        // the year itself is now optional (`template.yearFolder`). Whatever this
        // decides, `PathPlanner.plan` must decide identically: the preview tree
        // and the copy are computed by different code from the same template,
        // and a preview that shows one tree while the bytes go to another is the
        // exact dishonesty this app exists not to commit.
        let components = PathPlanner.sanitizedComponents(TemplateRenderer.render(template.folder, context))
        // Never produce a nameless folder — fall back to the ISO date if the
        // template renders nothing usable.
        let safeComponents = components.isEmpty
            ? [String(format: "%04d-%02d-%02d", year, c.month ?? 1, c.day ?? 1)]
            : components

        var dir = template.yearFolder
            ? destinationRoot.appendingPathComponent(String(year), isDirectory: true)
            : destinationRoot
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
        startingAt: Int = 0,
        /// 1-based position in the job, for `{Sequence}`. 0 means "no sequence",
        /// which renders the token empty and drops its optional group.
        sequence: Int = 0,
        isTaken: (URL) -> Bool = { _ in false }
    ) -> BundlePlan {
        let primary = bundle.primary
        let primaryOldName = primary.url.lastPathComponent
        let primaryOldStem = primary.url.deletingPathExtension().lastPathComponent
        let primaryExt = primary.url.pathExtension

        let destDir = destinationDirectory(for: bundle, destinationRoot: destinationRoot, description: description, template: template, cardLabel: cardLabel)
        let baseStem = baseStem(for: bundle, description: description, template: template,
                                cardLabel: cardLabel, sequence: sequence)

        // Smallest disambiguator at or above `startingAt` (0 = none) that frees
        // every file in the bundle. `taken` is a finite set (on-disk +
        // already-claimed), so some `n` is always free; this terminates.
        var n = max(0, startingAt)
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
            let files = separateInternalCollisions(buildFiles(
                bundle: bundle,
                primaryOldName: primaryOldName,
                primaryNewName: primaryNewName,
                primaryNewStem: primaryNewStem,
                destDir: destDir
            ))
            if !files.contains(where: { isTaken($0.destination) }) {
                return BundlePlan(bundle: bundle, files: files, disambiguator: n)
            }
            n += 1
        }
    }

    /// The rendered, sanitized primary stem before any `_n` suffix — the string
    /// two bundles have to share to collide. Extracted so `planBatch`'s
    /// disambiguator hint keys on exactly what `plan` will name the file, rather
    /// than on an approximation that could drift from it.
    static func baseStem(for bundle: AssetBundle, description: String,
                         template: NamingTemplate, cardLabel: String,
                         sequence: Int = 0) -> String {
        let primary = bundle.primary
        let context = TemplateContext(
            date: primary.dateTaken,
            description: PathPlanner.sanitize(description),
            originalName: primary.url.lastPathComponent,
            originalStem: primary.url.deletingPathExtension().lastPathComponent,
            cardLabel: PathPlanner.sanitize(cardLabel),
            cameraModel: PathPlanner.sanitize(primary.cameraModel),
            bodySerial: PathPlanner.sanitize(primary.bodySerial),
            sequence: sequence
        )
        let rendered = PathPlanner.sanitize(TemplateRenderer.render(template.filename, context))
        return rendered.isEmpty
            ? fallbackStem(date: primary.dateTaken,
                           stem: primary.url.deletingPathExtension().lastPathComponent)
            : rendered
    }

    /// Give each file in a bundle a distinct destination.
    ///
    /// `isTaken` structurally cannot see a collision *within* a bundle —
    /// `planBatch` inserts a bundle's paths only after `plan` returns — and the
    /// `n` loop above cannot resolve one either: companions derive their names
    /// from the primary's stem, so every file moves together and an internal
    /// duplicate survives at every `n`. Adding the internal check to that loop
    /// would spin it forever.
    ///
    /// Reachable because `classifyCompanion` matches sidecars by stem *prefix*:
    /// `IMG_1234.xmp` and `IMG_1234.v2.xmp` beside `IMG_1234.CR2` both classify as
    /// short-form sidecars and both render to `{newStem}.xmp`. Before this, they
    /// planned onto one path, `O_EXCL` refused the second, and the entire bundle
    /// — the RAW included — failed and rolled back. Suffixing the later file keeps
    /// the bundle atomic and loses nothing; the primary is index 0 and is never
    /// the one moved.
    private static func separateInternalCollisions(_ files: [PlannedFile]) -> [PlannedFile] {
        var seen = Set<String>()
        var result: [PlannedFile] = []
        result.reserveCapacity(files.count)
        for file in files {
            var destination = file.destination
            if !seen.insert(collisionKey(destination.path)).inserted {
                let dir = destination.deletingLastPathComponent()
                let ext = destination.pathExtension
                let stem = destination.deletingPathExtension().lastPathComponent
                var n = 1
                repeat {
                    destination = dir.appendingPathComponent(
                        PathPlanner.fileName(stem: "\(stem)_\(n)", extension: ext))
                    n += 1
                } while !seen.insert(collisionKey(destination.path)).inserted
            }
            result.append(PlannedFile(source: file.source, destination: destination,
                                      size: file.size, role: file.role))
        }
        return result
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
