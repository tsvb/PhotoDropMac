import Foundation

// Everything `stat(2)` tells us about a file's identity, short of reading it.
// Nanosecond timestamps come straight from the kernel — `URLResourceValues`
// rounds them into a `Date`, which is what made the old validator so loose.
struct FileIdentity: Sendable, Hashable {
    let size: Int64
    let mtimeNanos: Int64   // full-precision modification time
    let birthNanos: Int64   // creation time; 0 where the filesystem has none
    var mtimeSeconds: Double { Double(mtimeNanos) / 1_000_000_000 }
}

// One hash entry — what we think the content digest of a given file is,
// along with the identity we last saw it at. A re-check against a matching
// identity is trusted without a re-read.
struct HashCacheEntry: Codable, Sendable, Hashable {
    let hash: UInt64
    let size: Int64
    let mtime: Double        // seconds since 1970 (retained for readability/compat)
    let mtimeNanos: Int64?   // nil in caches written before this field existed
    let birthNanos: Int64?

    /// Whether this cached digest may be reused for a file with `identity`.
    ///
    /// **A stale hit here silently drops a photo.** The source-side cache key is
    /// `<volumeUUID>|<path>`, and on a camera card every part of it is chosen by
    /// whoever formatted and wrote the card: `volumeUUID` degrades to the 32-bit
    /// FAT/exFAT volume serial (and, failing that, to the mount path, i.e. the
    /// volume label), while the path, size, and timestamps are just card
    /// contents. A false hit hands `DestinationIndex.findDuplicate` some other
    /// file's digest, the bundle is skipped as a duplicate, and — because
    /// skipped entries are recorded with `xxhash64: nil` and `VerifyEngine`
    /// ignores null-hash entries — the file that never arrived is invisible to
    /// every later verify. Cheap cards ship with duplicate volume serials and
    /// cameras reuse `DCIM/…/DSC00001.JPG`, so this is reachable by accident,
    /// not just by an attacker.
    ///
    /// So the match is now exact on full-precision mtime plus creation time,
    /// where the old rule allowed a full second of mtime slop. Two distinct
    /// files agreeing on size *and* nanosecond mtime *and* birth time by chance
    /// is not a realistic collision, and forging it requires authoring the
    /// filesystem image while already knowing the victim's earlier card's
    /// timestamps to the nanosecond.
    ///
    /// Entries from an older cache (no `mtimeNanos`) fail closed — the digest is
    /// recomputed. That costs one re-hash per file, once.
    ///
    /// Inode is deliberately *not* part of this: exFAT inode numbers are
    /// synthesized by the kernel and are not stable across mounts, so requiring
    /// one would miss on every card and defeat the cache entirely.
    func matches(_ identity: FileIdentity) -> Bool {
        guard let mtimeNanos, let birthNanos else { return false }
        return size == identity.size
            && mtimeNanos == identity.mtimeNanos
            && birthNanos == identity.birthNanos
    }

    init(hash: UInt64, identity: FileIdentity) {
        self.hash = hash
        self.size = identity.size
        self.mtime = identity.mtimeSeconds
        self.mtimeNanos = identity.mtimeNanos
        self.birthNanos = identity.birthNanos
    }
}

// Persistent file-hash cache for dedup speedup.
//
// On a second dedup run against the same card + destination, the SD card
// read (the bottleneck) is skipped entirely — every file stats, hits the
// cache on (size, mtime), and returns the stored hash without reading the
// file at all. What used to cost ~100s for a 7.5 GB re-run drops to the
// couple seconds it takes to stat 358 files.
//
// Keys:
//   source  — "<volumeUUID>|<abspath>"    (volumeUUID makes two cards
//                                          with the same mount name
//                                          distinct)
//   dest    — "<abspath>"                 (destinations live on the user's
//                                          machine; path is stable)
actor HashCache {
    private var source: [String: HashCacheEntry] = [:]
    private var dest: [String: HashCacheEntry] = [:]
    private let storeURL: URL
    private var isDirty: Bool = false

    init(storeURL: URL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode(StoredForm.self, from: data) {
            self.source = stored.source
            self.dest = stored.dest
        }
    }

    // Lookup-or-compute for a source file. Returns nil only if the file
    // can't be stat'd or hashed (a permissions/IO error); callers treat
    // nil as "not a dedup candidate".
    func sourceHash(volumeUUID: String, url: URL) async -> UInt64? {
        guard let identity = statAttrs(url) else { return nil }
        let key = "\(volumeUUID)|\(url.path)"
        if let entry = source[key], entry.matches(identity) {
            return entry.hash
        }
        guard let computed = await computeHash(url: url) else { return nil }
        source[key] = HashCacheEntry(hash: computed, identity: identity)
        isDirty = true
        return computed
    }

    // Lookup-or-compute for a destination file.
    func destinationHash(url: URL) async -> UInt64? {
        guard let identity = statAttrs(url) else { return nil }
        let key = url.path
        if let entry = dest[key], entry.matches(identity) {
            return entry.hash
        }
        guard let computed = await computeHash(url: url) else { return nil }
        dest[key] = HashCacheEntry(hash: computed, identity: identity)
        isDirty = true
        return computed
    }

    // Record a destination hash that we already computed elsewhere —
    // typically right after a tee-hash copy + verification passes. Saves
    // re-hashing that file on the next dedup run.
    func recordDestination(url: URL, hash: UInt64) {
        guard let identity = statAttrs(url) else { return }
        dest[url.path] = HashCacheEntry(hash: hash, identity: identity)
        isDirty = true
    }

    func save() throws {
        guard isDirty else { return }
        let stored = StoredForm(source: source, dest: dest)
        let data = try JSONEncoder().encode(stored)
        let dir = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: storeURL, options: [.atomic])
        isDirty = false
    }

    // MARK: - Helpers

    /// Reads the file's identity via `stat(2)` rather than `URLResourceValues`,
    /// which rounds timestamps into a `Date` and so cannot express the
    /// nanosecond precision `HashCacheEntry.matches` depends on.
    private func statAttrs(_ url: URL) -> FileIdentity? {
        var st = stat()
        guard url.withUnsafeFileSystemRepresentation({ path -> Bool in
            guard let path else { return false }
            return stat(path, &st) == 0
        }) else { return nil }

        func nanos(_ ts: timespec) -> Int64 { Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec) }
        return FileIdentity(size: Int64(st.st_size),
                            mtimeNanos: nanos(st.st_mtimespec),
                            birthNanos: nanos(st.st_birthtimespec))
    }

    private func computeHash(url: URL) async -> UInt64? {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try XxHash64.hash(fileAt: url)
            }.value
        } catch {
            return nil
        }
    }

    nonisolated static var defaultURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("PhotoDropMac", isDirectory: true)
        return dir.appendingPathComponent("hash-cache.json")
    }

    private struct StoredForm: Codable {
        let source: [String: HashCacheEntry]
        let dest: [String: HashCacheEntry]
    }
}
