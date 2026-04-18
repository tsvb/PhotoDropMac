import Foundation

// A cheap, size-indexed snapshot of a destination root used for duplicate
// detection. Built by walking the directory tree for regular files and
// bucketing by file size. No hashing is done up front — hashes are
// computed (or fetched from the cache) only when a size collision
// actually occurs.
//
// Matches the Windows PhotoDrop DuplicateDetectionService semantics:
//   - "Dedup halts on size+hash match anywhere under the destination root,
//     not just path collision." → if the user renamed a previously-ingested
//     file, we still detect it.
struct DestinationIndex: Sendable {
    let bySize: [Int64: [URL]]

    static func build(at root: URL) -> DestinationIndex {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            return DestinationIndex(bySize: [:])
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return DestinationIndex(bySize: [:])
        }

        var bySize: [Int64: [URL]] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            bySize[size, default: []].append(url)
        }
        return DestinationIndex(bySize: bySize)
    }

    // Both source and destination hashes route through the cache. Cold
    // cache: reads the file, hashes it, stores. Warm cache (same file,
    // same mtime/size): stat-only — no file read. That's the big win for
    // re-ingests of the same card against the same destination.
    func findDuplicate(
        sourceSize: Int64,
        sourceVolumeID: String,
        sourceURL: URL,
        using cache: HashCache
    ) async -> URL? {
        guard let candidates = bySize[sourceSize], !candidates.isEmpty else { return nil }
        guard let sourceHash = await cache.sourceHash(volumeUUID: sourceVolumeID, url: sourceURL) else {
            return nil
        }
        for candidate in candidates {
            if let candidateHash = await cache.destinationHash(url: candidate),
               candidateHash == sourceHash {
                return candidate
            }
        }
        return nil
    }
}
