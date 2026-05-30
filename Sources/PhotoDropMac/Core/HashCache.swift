import Foundation

// One hash entry — what we think the content digest of a given file is,
// along with the size and mtime we last saw it at. A re-check with the
// same (size, mtime) is trusted without a re-read.
struct HashCacheEntry: Codable, Sendable, Hashable {
    let hash: UInt64
    let size: Int64
    let mtime: Double  // seconds since 1970

    func matches(size: Int64, mtime: Date) -> Bool {
        // mtime can drift by sub-second on some filesystems; allow a
        // one-second slop. Size is compared strictly.
        self.size == size
            && abs(self.mtime - mtime.timeIntervalSince1970) < 1.0
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
        guard let (size, mtime) = statAttrs(url) else { return nil }
        let key = "\(volumeUUID)|\(url.path)"
        if let entry = source[key], entry.matches(size: size, mtime: mtime) {
            return entry.hash
        }
        guard let computed = await computeHash(url: url) else { return nil }
        source[key] = HashCacheEntry(hash: computed, size: size, mtime: mtime.timeIntervalSince1970)
        isDirty = true
        return computed
    }

    // Lookup-or-compute for a destination file.
    func destinationHash(url: URL) async -> UInt64? {
        guard let (size, mtime) = statAttrs(url) else { return nil }
        let key = url.path
        if let entry = dest[key], entry.matches(size: size, mtime: mtime) {
            return entry.hash
        }
        guard let computed = await computeHash(url: url) else { return nil }
        dest[key] = HashCacheEntry(hash: computed, size: size, mtime: mtime.timeIntervalSince1970)
        isDirty = true
        return computed
    }

    // Record a destination hash that we already computed elsewhere —
    // typically right after a tee-hash copy + verification passes. Saves
    // re-hashing that file on the next dedup run.
    func recordDestination(url: URL, hash: UInt64) {
        guard let (size, mtime) = statAttrs(url) else { return }
        dest[url.path] = HashCacheEntry(hash: hash, size: size, mtime: mtime.timeIntervalSince1970)
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

    private func statAttrs(_ url: URL) -> (Int64, Date)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let mtime = values.contentModificationDate
        else {
            return nil
        }
        return (Int64(size), mtime)
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
