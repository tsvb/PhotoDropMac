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
