import Foundation

// A cheap, size-indexed snapshot of a destination root used for duplicate
// detection. Built by walking the directory tree for regular files and
// bucketing by file size. No hashing is done up front — hashes are
// computed lazily only when a size collision actually occurs.
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

    // If a destination file of the same size has a matching xxhash64,
    // return its URL. The source hash is computed (via `sourceHashProvider`)
    // only when at least one size collision exists — most first-time
    // ingests hit zero collisions and pay nothing.
    func findDuplicate(
        sourceSize: Int64,
        sourceHashProvider: () throws -> UInt64
    ) throws -> URL? {
        guard let candidates = bySize[sourceSize], !candidates.isEmpty else { return nil }
        let sourceHash = try sourceHashProvider()
        for candidate in candidates {
            if let candidateHash = try? XxHash64.hash(fileAt: candidate),
               candidateHash == sourceHash {
                return candidate
            }
        }
        return nil
    }
}
