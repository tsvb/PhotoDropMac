import Foundation

// Progress + result value types for re-verification. Value types (Sendable) so
// they cross the off-main engine / main-actor controller boundary freely and are
// reusable by the CLI.

struct VerifyProgress: Sendable, Equatable {
    let total: Int
    let checked: Int
    let currentFile: String
    var fraction: Double { total == 0 ? 0 : Double(checked) / Double(total) }
}

struct VerifyIssue: Sendable, Identifiable, Equatable, Hashable {
    /// `conflict` means two manifests recorded *different* digests for the same
    /// file — the library's own records disagree, so no verdict can be trusted.
    enum Kind: Sendable { case changed, missing, unreadable, conflict }
    let id = UUID()
    let name: String
    let path: String
    let kind: Kind
}

struct VerifyReport: Sendable, Equatable {
    let verified: Int
    let issues: [VerifyIssue]
    let manifestCount: Int
    /// Directories the walk could not open (xattr mode only).
    ///
    /// The enumerator was created without an error handler, so a subtree that
    /// couldn't be read — mode `0000`, or a NAS mount dropping mid-walk — was
    /// skipped in silence and the run printed `✓ All 4,200 files match` over a
    /// library a third of which was never opened. A verification tool must never
    /// count files it didn't visit as evidence of anything.
    let unreadableDirectories: Int
    /// Files present but carrying no checksum attribute (xattr mode only).
    ///
    /// Unstamped files were dropped without a tally, so a library round-tripped
    /// through anything that strips xattrs — some cloud sync, `cp -X`, a
    /// zip/unzip restore — reported `✓ All 1,000 files match` over 10,000 files.
    /// "The stamp was lost" and "it was never stamped" are indistinguishable from
    /// the outside, so the honest report is the count.
    let unstamped: Int

    init(verified: Int, issues: [VerifyIssue], manifestCount: Int,
         unreadableDirectories: Int = 0, unstamped: Int = 0) {
        self.verified = verified
        self.issues = issues
        self.manifestCount = manifestCount
        self.unreadableDirectories = unreadableDirectories
        self.unstamped = unstamped
    }

    var changed: Int { issues.lazy.filter { $0.kind == .changed }.count }
    var missing: Int { issues.lazy.filter { $0.kind == .missing }.count }
    var unreadable: Int { issues.lazy.filter { $0.kind == .unreadable }.count }
    var conflicts: Int { issues.lazy.filter { $0.kind == .conflict }.count }
    var total: Int { verified + issues.count }
    /// No issues **and** nothing the walk was unable to reach. A clean verdict has
    /// to cover the whole target, not just the part that was reachable.
    ///
    /// `unstamped` is deliberately *not* a failure condition: `FileChecksumXattr`
    /// states that an absent attribute means "unstamped", never "changed", and
    /// failing on it would make every partially-stamped library exit 1 — the
    /// nightly-alarm-that-cries-wolf failure the scheduled-verify exit codes were
    /// split to avoid. It is always *reported*, and a run where nothing at all
    /// could be checked is refused separately by the CLI.
    var allGood: Bool { issues.isEmpty && unreadableDirectories == 0 }
}

/// Tally shared with the xattr walk's error handler — see `UnreadableCounter` in
/// `AssetDiscovery` for why this is a locked class rather than a captured `var`.
private final class XattrWalkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Headless re-verification engine. Reads the manifest(s) at `target`, re-hashes
/// every recorded file (reading past the page cache), and reports matches /
/// changed / missing / unreadable. Synchronous and nonisolated — callers run it
/// off the main actor: the `Verifier` controller via a detached `Task`, the CLI
/// directly. The manifest is the source of truth, independent of the dedup
/// cache's mtime validation.
enum VerifyEngine {
    struct WorkItem: Sendable {
        let url: URL          // absolute path to the file on disk
        let relPath: String   // path relative to the library root, for display
        let name: String
        let expected: UInt64
        /// Mirror roots recorded for this file, in manifest order. Unused by
        /// verification itself — `HealEngine` reads it to look for a healthy
        /// copy — but it is assembled here so both engines derive everything
        /// they know about a file from one trust-checked pass over the
        /// manifests. Untrusted: a mirror is only ever *offered* after its
        /// contents hash to `expected`.
        let mirrors: [URL]
    }

    /// Run the full verification. Calls `onProgress` after each file and aborts
    /// (returning `nil`) once `isCancelled()` becomes true. Otherwise returns a
    /// report — `report.total == 0` means there was nothing to check.
    static func run(target: URL,
                    isCancelled: () -> Bool = { false },
                    onProgress: (VerifyProgress) -> Void = { _ in }) -> VerifyReport? {
        let (work, manifestCount, conflicts) = build(target: target)
        var verified = 0
        var issues: [VerifyIssue] = conflicts
        let total = work.count

        for (i, item) in work.enumerated() {
            if isCancelled() { return nil }
            switch check(item) {
            case .verified:   verified += 1
            case .changed:    issues.append(VerifyIssue(name: item.name, path: item.relPath, kind: .changed))
            case .missing:    issues.append(VerifyIssue(name: item.name, path: item.relPath, kind: .missing))
            case .unreadable: issues.append(VerifyIssue(name: item.name, path: item.relPath, kind: .unreadable))
            }
            onProgress(VerifyProgress(total: total, checked: i + 1, currentFile: item.name))
        }

        return VerifyReport(verified: verified, issues: issues, manifestCount: manifestCount)
    }

    /// Reads every manifest near `target` and flattens it into a deduped list of
    /// files to re-hash. Each entry's file is resolved relative to its manifest's
    /// library root (two levels up from the JSON) via
    /// `ManifestWriter.resolve(entryPath:under:)`, which drops any entry that
    /// escapes that root — see the security note there.
    ///
    /// **Disagreement between manifests is reported, never resolved.** Manifests
    /// are unauthenticated files sitting in a folder anyone who can write to the
    /// library can add to, and every ordering signal available (the in-file
    /// `createdAt`, the `ingest-<stamp>` filename, the file's mtime) is chosen by
    /// whoever wrote the file. A "newest wins" rule therefore hands control of
    /// the expected digest to the most recently *claimed* manifest: dropping in
    /// one JSON dated 2099 silently overrides every real hash and turns a
    /// tampered file green, without touching the genuine manifest at all.
    ///
    /// So: two manifests recording the same digest for a path is normal (a
    /// re-ingest re-records what it skipped) and dedupes quietly, but two
    /// recording *different* digests yields a `.conflict` issue. This can't
    /// arise from honest use — `CopyPlan` is collision-safe and never rewrites an
    /// existing path — so a conflict means either real corruption of a manifest
    /// or a planted one. Either way the library can no longer vouch for that
    /// file, which is exactly what the report should say.
    static func build(target: URL) -> (items: [WorkItem], manifestCount: Int, conflicts: [VerifyIssue]) {
        // Decode every manifest, then order oldest → newest. This ordering is
        // only for deterministic output — it is explicitly *not* trusted to
        // arbitrate between manifests (see above).
        var loaded: [(createdAt: Date, urlPath: String, root: URL, mirrors: [URL], files: [ManifestEntry])] = []
        for manifestURL in ManifestWriter.manifestURLs(near: target) {
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = ManifestWriter.decode(data) else { continue }
            let root = manifestURL.deletingLastPathComponent().deletingLastPathComponent()
            // Recorded destinations (primary at 0, then mirrors); fall back for
            // manifests written before the `destinations` field existed.
            let recorded = manifest.destinations
                ?? ([manifest.primaryDestination] + (manifest.archiveDestination.map { [$0] } ?? []))
            let mirrors = recorded.dropFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
            loaded.append((manifest.createdAt, manifestURL.path, root, mirrors, manifest.files))
        }
        loaded.sort { ($0.createdAt, $0.urlPath) < ($1.createdAt, $1.urlPath) }

        var byPath: [String: WorkItem] = [:]
        var conflicted: [String: VerifyIssue] = [:]
        for record in loaded {
            for entry in record.files {
                guard let hex = entry.xxhash64, let expected = UInt64(hex, radix: 16) else { continue }
                // Untrusted path: dropped outright if it escapes the library root.
                guard let fileURL = ManifestWriter.resolve(entryPath: entry.path, under: record.root) else { continue }
                let key = fileURL.path
                if let existing = byPath[key], existing.expected != expected {
                    conflicted[key] = VerifyIssue(name: entry.name, path: existing.relPath, kind: .conflict)
                    continue
                }
                // Manifests that *agree* on the digest contribute their mirrors to
                // one candidate list. Safe to union because a listed mirror is
                // only ever used after its bytes hash to `expected`; a wider list
                // just means more places a healthy copy might be found.
                var mirrors = byPath[key]?.mirrors ?? []
                let known = Set(mirrors.map(\.path))
                mirrors += record.mirrors.filter { !known.contains($0.path) }
                // The *resolved* relative path, never the manifest's string — see
                // `ManifestWriter.relativePath`. Everything downstream (issues,
                // heal candidates, the restore script, the mirror lookup) reads
                // this, so re-rooting has to be reflected here or the report
                // names a file that was never inspected.
                byPath[key] = WorkItem(url: fileURL,
                                       relPath: ManifestWriter.relativePath(of: fileURL, under: record.root),
                                       name: entry.name, expected: expected, mirrors: mirrors)
            }
        }

        // A file whose manifests disagree is never hashed — there is no expected
        // value to hash it against. It is reported as a conflict instead.
        for key in conflicted.keys { byPath.removeValue(forKey: key) }

        // Path-sorted output so progress and the report are deterministic.
        let items = byPath.values.sorted { $0.relPath < $1.relPath }
        let conflicts = conflicted.values.sorted { $0.path < $1.path }
        return (items, loaded.count, conflicts)
    }

    /// What an xattr verification run concluded.
    ///
    /// "Couldn't read the target" is a distinct outcome from "read it, nothing
    /// was stamped", and collapsing the two is how a verification tool ends up
    /// reporting success on a folder it never opened: a typo'd path, or one whose
    /// permissions changed, printed "No checksummed files found" and exited 0
    /// forever. `FileManager`'s enumerator is lazy and swallows its errors, so
    /// the difference has to be established up front.
    enum XattrOutcome: Sendable {
        case report(VerifyReport)
        case unreadableTarget
        case cancelled
    }

    /// Manifest-free verification: walk `folder`, and for every regular file
    /// that carries a `FileChecksumXattr` digest, re-hash it (past the page
    /// cache) and compare. Files without the xattr are skipped (unstamped, not an
    /// issue), so this works on any subtree even after the library is reorganized
    /// or the manifest is gone. `manifestCount` is 0 (this path doesn't use one).
    static func runXattr(folder: URL,
                         isCancelled: () -> Bool = { false },
                         onProgress: (VerifyProgress) -> Void = { _ in }) -> XattrOutcome {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isReadableFile(atPath: folder.path) else {
            return .unreadableTarget
        }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        // The error handler is what keeps an unreadable subtree from being
        // silently skipped — see `VerifyReport.unreadableDirectories`.
        let unreadableDirectories = XattrWalkCounter()
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { _, _ in unreadableDirectories.increment(); return true }) else {
            return .unreadableTarget
        }

        var items: [(url: URL, rel: String, expected: UInt64)] = []
        var unstamped = 0
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            // The manifests are the record, not library content. They are never
            // stamped, so counting them as "files that went unchecked" would put
            // a permanent floor of 2 on every clean report — noise that trains
            // the reader to ignore the number, which is the one thing it cannot
            // afford to be.
            guard !url.pathComponents.contains(ManifestWriter.folderName) else { continue }
            guard let expected = FileChecksumXattr.read(from: url) else { unstamped += 1; continue }
            items.append((url, relativePath(of: url, under: folder), expected))
        }
        items.sort { $0.rel < $1.rel }

        var verified = 0
        var issues: [VerifyIssue] = []
        for (i, item) in items.enumerated() {
            if isCancelled() { return .cancelled }
            if let actual = try? XxHash64.hash(fileAt: item.url, bypassCache: true) {
                if actual == item.expected { verified += 1 }
                else { issues.append(VerifyIssue(name: item.url.lastPathComponent, path: item.rel, kind: .changed)) }
            } else {
                issues.append(VerifyIssue(name: item.url.lastPathComponent, path: item.rel, kind: .unreadable))
            }
            onProgress(VerifyProgress(total: items.count, checked: i + 1, currentFile: item.url.lastPathComponent))
        }
        return .report(VerifyReport(verified: verified, issues: issues, manifestCount: 0,
                                    unreadableDirectories: unreadableDirectories.value,
                                    unstamped: unstamped))
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        if urlComponents.count > rootComponents.count,
           Array(urlComponents.prefix(rootComponents.count)) == rootComponents {
            return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }
        return url.path(percentEncoded: false)
    }

    enum CheckResult { case verified, changed, missing, unreadable }

    static func check(_ item: WorkItem) -> CheckResult {
        guard FileManager.default.fileExists(atPath: item.url.path) else { return .missing }
        do {
            // Read past the page cache so we re-hash what is actually on the
            // device — the whole point of a bit-rot check. Mirrors the copy
            // engine's post-write verify, which also bypasses the cache.
            let actual = try XxHash64.hash(fileAt: item.url, bypassCache: true)
            return actual == item.expected ? .verified : .changed
        } catch {
            return .unreadable
        }
    }
}
