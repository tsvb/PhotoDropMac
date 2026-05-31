import Foundation
import Darwin

// A cheap, size-indexed snapshot of a destination root used for duplicate
// detection. Built by walking the directory tree for regular files and
// bucketing by file size. No hashing is done up front — hashes are computed
// (or fetched from the cache) only when a size collision actually occurs.
//
// Dedup is content-based, not path-based: a file counts as a duplicate when
// its size and hash match anything anywhere under the destination root, not
// just a same-path collision — so a previously-ingested file the user later
// renamed is still detected.
//
// On APFS/HFS+ the walk is incremental across runs: a per-directory mtime
// snapshot is persisted, and on the next run only directories whose mtime
// changed are re-listed. Adding, removing, or renaming an entry bumps its
// parent directory's mtime, so a newly-added file is always re-discovered.
// On other filesystems (exFAT/SMB, whose directory-mtime semantics aren't
// dependable) it falls back to a full walk and persists nothing.
//
// Safety: this index drives *dedup only*, which is staleness-tolerant — a
// missed entry causes at most a redundant copy, never an overwrite. Collision-
// safe naming deliberately does NOT use this index; it scans just the target
// folders fresh every time (see `existingFilePaths`). That separation is what
// lets the dedup index be cached safely. (Caveat: an *in-place* rewrite that
// changes a file's size without touching its directory — e.g. a sidecar
// re-saved by an editor — can leave a stale size until the directory otherwise
// changes. Harmless here for the reason above.)
struct DestinationIndex: Sendable {
    let bySize: [Int64: [URL]]

    // Both source and destination hashes route through the cache. Cold cache:
    // reads the file, hashes it, stores. Warm cache (same file, same
    // mtime/size): stat-only — no file read.
    func findDuplicate(
        sourceSize: Int64,
        sourceVolumeID: String,
        sourceURL: URL,
        using cache: HashCache
    ) async -> URL? {
        // Never dedup zero-byte files: every empty file shares size 0 and the
        // same (constant) empty-input hash, so treating them as duplicates would
        // skip a distinct empty companion as a "duplicate" of an unrelated empty
        // file — silently dropping it from its bundle. Always copy them instead.
        guard sourceSize > 0 else { return nil }
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

    // MARK: - Collision-safety scan (always fresh, never cached)

    /// Paths of the entries that already exist directly inside `directories`.
    /// Collision-safe naming only needs to know what's in the exact day-folders
    /// a job writes into — never the whole library — so this is a cheap, direct
    /// listing, deliberately independent of the (possibly cached) dedup index.
    /// Keeping it independent is what makes the cached index safe: a stale dedup
    /// entry can never cause an overwrite because the name check never trusts
    /// it. Subdirectories are included too — a planned file can't be written
    /// where a directory already sits.
    static func existingFilePaths(in directories: Set<URL>) -> Set<String> {
        let fm = FileManager.default
        var paths = Set<String>()
        for dir in directories {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            // Reconstruct each path from `dir`, not from the enumerated URL:
            // FileManager resolves symlinks in returned URLs (e.g. /var →
            // /private/var), which would otherwise never string-match a planned
            // destination built from the same `dir`.
            for url in entries { paths.insert(dir.appendingPathComponent(url.lastPathComponent).path) }
        }
        return paths
    }

    // MARK: - Build

    static func build(at root: URL, storeURL: URL = DestinationIndex.defaultStoreURL) -> DestinationIndex {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return DestinationIndex(bySize: [:])
        }
        if isIncrementalSupported(root) {
            return buildIncremental(at: root, storeURL: storeURL)
        }
        return DestinationIndex(bySize: fullWalk(at: root))
    }

    // MARK: - Full walk (non-native FS; nothing persisted)

    private static func fullWalk(at root: URL) -> [Int64: [URL]] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let keySet = Set(keys)   // hoisted out of the loop
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return [:]
        }
        var bySize: [Int64: [URL]] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            bySize[size, default: []].append(url)
        }
        return bySize
    }

    // MARK: - Incremental walk (APFS/HFS+; mtime-validated, persisted)

    private struct DirSnapshot: Codable {
        let mtime: Int64             // the directory's mtime, in nanoseconds
        let files: [String: Int64]   // filename -> size
        let subdirs: [String]        // subdirectory names (packages excluded)
    }
    private typealias RootSnapshot = [String: DirSnapshot]   // dirPath -> snapshot

    private static let scanKeyArray: [URLResourceKey] =
        [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isPackageKey]
    private static let scanKeySet = Set(scanKeyArray)

    private static func buildIncremental(at root: URL, storeURL: URL) -> DestinationIndex {
        let cached = loadSnapshot(rootPath: root.path, storeURL: storeURL)
        var fresh: RootSnapshot = [:]
        var bySize: [Int64: [URL]] = [:]
        scanDirectory(root, cached: cached, fresh: &fresh, bySize: &bySize)
        saveSnapshot(fresh, rootPath: root.path, storeURL: storeURL)
        return DestinationIndex(bySize: bySize)
    }

    private static func scanDirectory(
        _ dir: URL,
        cached: RootSnapshot,
        fresh: inout RootSnapshot,
        bySize: inout [Int64: [URL]]
    ) {
        let mtime = directoryMTime(dir)

        // Unchanged directory: reuse its cached file sizes, but still recurse
        // into its subdirs — a grandchild change doesn't touch this dir's mtime.
        if let snap = cached[dir.path], let mtime, snap.mtime == mtime {
            for (name, size) in snap.files {
                bySize[size, default: []].append(dir.appendingPathComponent(name))
            }
            fresh[dir.path] = snap
            for sub in snap.subdirs {
                scanDirectory(dir.appendingPathComponent(sub, isDirectory: true),
                              cached: cached, fresh: &fresh, bySize: &bySize)
            }
            return
        }

        // Changed or never-seen: re-list it.
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: scanKeyArray,
            options: [.skipsHiddenFiles]
        ) else {
            fresh[dir.path] = DirSnapshot(mtime: mtime ?? 0, files: [:], subdirs: [])
            return
        }

        var files: [String: Int64] = [:]
        var subdirs: [String] = []
        for url in entries {
            guard let v = try? url.resourceValues(forKeys: scanKeySet) else { continue }
            if v.isDirectory == true {
                if v.isPackage == true { continue }   // don't descend into bundles
                subdirs.append(url.lastPathComponent)
                scanDirectory(url, cached: cached, fresh: &fresh, bySize: &bySize)
            } else if v.isRegularFile == true {
                let size = Int64(v.fileSize ?? 0)
                files[url.lastPathComponent] = size
                bySize[size, default: []].append(url)
            }
        }
        fresh[dir.path] = DirSnapshot(mtime: mtime ?? 0, files: files, subdirs: subdirs)
    }

    // Read mtime via POSIX stat rather than URL.resourceValues: the latter
    // caches the value on the URL instance, which can hand back a stale mtime if
    // the same URL is reused across builds. stat always reflects current state.
    // Nanoseconds keep the comparison exact (no float round-trip jitter).
    private static func directoryMTime(_ dir: URL) -> Int64? {
        var st = stat()
        guard stat(dir.path, &st) == 0 else { return nil }
        return Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    }

    // MARK: - Filesystem capability

    // Incremental scanning trusts that adding/removing/renaming a directory
    // entry bumps the directory's mtime — true on APFS and HFS+, not dependable
    // on FAT/exFAT/SMB. Anything else takes the full-walk path.
    private static func isIncrementalSupported(_ root: URL) -> Bool {
        var buf = statfs()
        guard statfs(root.path, &buf) == 0 else { return false }
        let fstype = withUnsafeBytes(of: &buf.f_fstypename) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return fstype == "apfs" || fstype == "hfs"
    }

    // MARK: - Persistence

    static var defaultStoreURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        return base.appendingPathComponent("PhotoDropMac", isDirectory: true)
            .appendingPathComponent("dest-index.json")
    }

    private static func loadStore(_ storeURL: URL) -> [String: RootSnapshot] {
        guard let data = try? Data(contentsOf: storeURL),
              let all = try? JSONDecoder().decode([String: RootSnapshot].self, from: data) else {
            return [:]
        }
        return all
    }

    private static func loadSnapshot(rootPath: String, storeURL: URL) -> RootSnapshot {
        loadStore(storeURL)[rootPath] ?? [:]
    }

    private static func saveSnapshot(_ snapshot: RootSnapshot, rootPath: String, storeURL: URL) {
        var all = loadStore(storeURL)
        all[rootPath] = snapshot
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: [.atomic])
    }
}
