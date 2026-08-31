import Foundation

/// Pre-copy sanity check: does each destination volume have room for the
/// planned bytes? Conservative — it assumes no dedup savings and sums the
/// requirement per volume, so a dual-destination ingest onto a single disk
/// needs 2×. Best-effort: a volume that can't be resolved (e.g. the folder
/// doesn't exist yet) is skipped rather than reported.
enum PreflightCheck {
    /// Returns a human-readable refusal if the source and destination trees
    /// overlap, or `nil` if the topology is safe.
    ///
    /// Distinct from `spaceWarning` and **not** overridable: a full disk still
    /// copies what fits, so "Ingest Anyway" is a reasonable offer there. An
    /// overlapping topology copies *nothing* while reporting success, so there is
    /// no version of proceeding that helps. `IngestEngine` enforces this too —
    /// this exists so the GUI says it before the user presses Ingest rather than
    /// after the job halts. See `DestinationTopology`.
    static func topologyRefusal(source: URL?, primary: URL, archives: [URL]) -> String? {
        let problems = DestinationTopology.check(source: source, roots: [primary] + archives)
        guard !problems.isEmpty else { return nil }
        return problems.map(\.message).joined(separator: "\n\n")
    }

    /// Returns a human-readable refusal if a configured destination folder does
    /// not exist, or `nil` if every root is present.
    ///
    /// **Not overridable, for the same reason as `topologyRefusal`.** The CLI has
    /// always refused a `--to` that doesn't exist, and the reasoning is recorded:
    /// `FileCopier` creates intermediate directories, so a typo'd destination
    /// materializes a whole new library tree and exits 0 with a manifest
    /// attesting to it. The GUI had no equivalent check anywhere on the path —
    /// `spaceWarning` skips a root whose volume won't resolve, and
    /// `DestinationTopology` accepts not-yet-existing paths by design (the
    /// unplugged-drive case) — so a destination the user renamed in Finder since
    /// picking it, or a share mounted somewhere other than `/Volumes`, silently
    /// became a *second* empty library: the dedup index found nothing, the whole
    /// card was re-copied, the sheet reported everything verified, and the card
    /// ejected. `/Volumes/X` survived only because that directory is root-owned.
    ///
    /// A path that exists but is not a directory is refused for the same reason:
    /// `createDirectory` would fail on every single file.
    ///
    /// This deliberately does **not** offer to create the folder. Choosing a
    /// destination is the user's decision and a typo is indistinguishable from an
    /// intent to create; the folder picker is right there.
    static func missingDestinations(primary: URL, archives: [URL]) -> String? {
        let fm = FileManager.default
        var missing: [String] = []
        var notFolders: [String] = []
        for root in [primary] + archives {
            var isDirectory: ObjCBool = false
            if !fm.fileExists(atPath: root.path, isDirectory: &isDirectory) {
                missing.append(root.path)
            } else if !isDirectory.boolValue {
                notFolders.append(root.path)
            }
        }
        guard !missing.isEmpty || !notFolders.isEmpty else { return nil }

        var parts: [String] = []
        if !missing.isEmpty {
            let list = missing.map { "“\($0)”" }.joined(separator: "\n")
            parts.append("""
            \(missing.count == 1 ? "This destination folder doesn’t exist" : "These destination folders don’t exist"):

            \(list)

            PhotoDrop won’t create it — a mistyped or moved destination would become a second, empty library and the ingest would report success over it. Check the volume is mounted, or choose the folder again.
            """)
        }
        if !notFolders.isEmpty {
            let list = notFolders.map { "“\($0)”" }.joined(separator: "\n")
            parts.append("""
            \(notFolders.count == 1 ? "This destination is a file, not a folder" : "These destinations are files, not folders"):

            \(list)
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Returns a human-readable warning naming mirrors that aren't currently
    /// reachable, or `nil` when every configured destination is present.
    ///
    /// Overridable, unlike `missingDestinations` — and the difference is the
    /// whole point. A missing **primary** is a mistake. A missing **mirror** is
    /// the routine travel case the 3-2-1 feature exists for: laptop in the field,
    /// NAS at home. `ArchiveDestinations.identity` tolerates an absent root
    /// deliberately for exactly this reason.
    ///
    /// What was wrong was discovering it 2,000 times instead of once. Nothing
    /// pre-flighted it, so every bundle failed at `createDirectory`, the log took
    /// 2,000 lines to say one thing, and `filesFailed` blocked the auto-eject even
    /// though the library was complete.
    static func unreachableMirrors(archives: [URL]) -> String? {
        let fm = FileManager.default
        let missing = archives.filter { !fm.fileExists(atPath: $0.path) }
        guard !missing.isEmpty else { return nil }

        let names = missing.map { "“\($0.lastPathComponent)”" }.joined(separator: ", ")
        let one = missing.count == 1
        let subject = one ? "isn’t available right now" : "aren’t available right now"
        let volumes = one ? "That volume may not be mounted."
                          : "Those volumes may not be mounted."
        let them = one ? "it" : "them"
        let theyre = one ? "it’s" : "they’re"
        return """
        \(names) \(subject). \(volumes)

        You can ingest to the other destinations now and bring \(them) up to date later by re-running the ingest, or with “photodrop sync” once \(theyre) back.
        """
    }

    /// Returns a human-readable warning if a destination volume looks too full,
    /// or `nil` if everything fits (or can't be checked).
    static func spaceWarning(plannedBytes: Int64, primary: URL, archives: [URL]) -> String? {
        guard plannedBytes > 0 else { return nil }

        var requiredByVolume: [URL: Int64] = [:]
        var nameByVolume: [URL: String] = [:]
        for dest in [primary] + archives {
            guard let volume = volumeRoot(of: dest) else { continue }
            requiredByVolume[volume, default: 0] += plannedBytes
            nameByVolume[volume] = volumeName(of: dest) ?? volume.lastPathComponent
        }

        // Report the volume that is furthest short, and break ties by path.
        // Iterating the dictionary directly and returning on the first hit made
        // the warning nondeterministic when two destinations were both too full:
        // the same configuration named a different volume from run to run.
        let shortfalls = requiredByVolume.compactMap { volume, required -> (URL, Int64, Int64)? in
            guard let free = availableCapacity(at: volume), free < required else { return nil }
            return (volume, free, required)
        }
        let worst = shortfalls.max { a, b in
            (a.2 - a.1, b.0.path) < (b.2 - b.1, a.0.path)
        }

        if let (volume, free, required) = worst {
            let name = nameByVolume[volume] ?? "The destination"
            return """
            “\(name)” has \(free.formatted(.byteCount(style: .file))) free, but this ingest needs about \(required.formatted(.byteCount(style: .file))).

            Duplicates already in the library aren’t re-copied, so it may still fit — or you can free up space / choose another destination.
            """
        }
        return nil
    }

    private static func availableCapacity(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private static func volumeRoot(of url: URL) -> URL? {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    private static func volumeName(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }
}
