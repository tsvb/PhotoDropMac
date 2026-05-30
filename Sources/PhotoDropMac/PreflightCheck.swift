import Foundation

/// Pre-copy sanity check: does each destination volume have room for the
/// planned bytes? Conservative — it assumes no dedup savings and sums the
/// requirement per volume, so a dual-destination ingest onto a single disk
/// needs 2×. Best-effort: a volume that can't be resolved (e.g. the folder
/// doesn't exist yet) is skipped rather than reported.
enum PreflightCheck {
    /// Returns a human-readable warning if a destination volume looks too full,
    /// or `nil` if everything fits (or can't be checked).
    static func spaceWarning(plannedBytes: Int64, primary: URL, archive: URL?) -> String? {
        guard plannedBytes > 0 else { return nil }

        var requiredByVolume: [URL: Int64] = [:]
        var nameByVolume: [URL: String] = [:]
        for dest in [primary, archive].compactMap({ $0 }) {
            guard let volume = volumeRoot(of: dest) else { continue }
            requiredByVolume[volume, default: 0] += plannedBytes
            nameByVolume[volume] = volumeName(of: dest) ?? volume.lastPathComponent
        }

        for (volume, required) in requiredByVolume {
            guard let free = availableCapacity(at: volume), free < required else { continue }
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
