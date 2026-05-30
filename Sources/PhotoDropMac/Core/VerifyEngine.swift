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
    enum Kind: Sendable { case changed, missing, unreadable }
    let id = UUID()
    let name: String
    let path: String
    let kind: Kind
}

struct VerifyReport: Sendable, Equatable {
    let verified: Int
    let issues: [VerifyIssue]
    let manifestCount: Int

    var changed: Int { issues.lazy.filter { $0.kind == .changed }.count }
    var missing: Int { issues.lazy.filter { $0.kind == .missing }.count }
    var unreadable: Int { issues.lazy.filter { $0.kind == .unreadable }.count }
    var total: Int { verified + issues.count }
    var allGood: Bool { issues.isEmpty }
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
    }

    /// Run the full verification. Calls `onProgress` after each file and aborts
    /// (returning `nil`) once `isCancelled()` becomes true. Otherwise returns a
    /// report — `report.total == 0` means there was nothing to check.
    static func run(target: URL,
                    isCancelled: () -> Bool = { false },
                    onProgress: (VerifyProgress) -> Void = { _ in }) -> VerifyReport? {
        let (work, manifestCount) = build(target: target)
        var verified = 0
        var issues: [VerifyIssue] = []
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
    /// library root (two levels up from the JSON).
    ///
    /// When several manifests record the same file (e.g. re-ingests), the most
    /// recent one wins: manifests are applied oldest-first by `createdAt`, so a
    /// file is verified against its latest known-good hash — deterministic
    /// regardless of the order the manifest files happen to be listed in.
    static func build(target: URL) -> (items: [WorkItem], manifestCount: Int) {
        // Decode every manifest, then order oldest → newest. The manifest's path
        // is a stable tiebreaker for the (practically impossible) case of two
        // equal createdAt timestamps.
        var loaded: [(createdAt: Date, urlPath: String, root: URL, files: [ManifestEntry])] = []
        for manifestURL in ManifestWriter.manifestURLs(near: target) {
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = ManifestWriter.decode(data) else { continue }
            let root = manifestURL.deletingLastPathComponent().deletingLastPathComponent()
            loaded.append((manifest.createdAt, manifestURL.path, root, manifest.files))
        }
        loaded.sort { ($0.createdAt, $0.urlPath) < ($1.createdAt, $1.urlPath) }

        // Newest-wins: iterating oldest → newest and overwriting by resolved path
        // means a file recorded by a later ingest verifies against that later hash.
        var byPath: [String: WorkItem] = [:]
        for record in loaded {
            for entry in record.files {
                guard let hex = entry.xxhash64, let expected = UInt64(hex, radix: 16) else { continue }
                let fileURL = record.root.appendingPathComponent(entry.path)
                byPath[fileURL.path] = WorkItem(url: fileURL, relPath: entry.path, name: entry.name, expected: expected)
            }
        }
        // Path-sorted output so progress and the report are deterministic.
        let items = byPath.values.sorted { $0.relPath < $1.relPath }
        return (items, loaded.count)
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
