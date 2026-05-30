import Foundation

struct HealCandidate: Sendable, Equatable {
    enum Kind: Sendable { case changed, missing }
    let relPath: String
    let kind: Kind
    let badPath: String            // where the damaged/absent primary copy belongs
    let recoverableFrom: String?   // a verified mirror copy's path, or nil if none exists
}

struct HealReport: Sendable {
    let healthy: Int
    let candidates: [HealCandidate]
    let manifestCount: Int

    var recoverable: [HealCandidate] { candidates.filter { $0.recoverableFrom != nil } }
    var unrecoverable: [HealCandidate] { candidates.filter { $0.recoverableFrom == nil } }
    var total: Int { healthy + candidates.count }
    var allHealthy: Bool { candidates.isEmpty }
}

/// Report-only "heal readiness" engine. Verifies a library against its manifests
/// and, for every damaged or missing file, reports whether a healthy copy still
/// exists in one of the recorded mirror destinations — and where.
///
/// It **never writes to the library**. The optional restore script is something
/// the user reviews and runs themselves; nothing here touches their files. (This
/// is the deliberately conservative posture chosen for the tool: diagnose
/// recoverability, never auto-overwrite — a "changed" file might be a real edit.)
enum HealEngine {
    private struct Item { let rel: String; let expected: UInt64; let primaryRoot: URL; let mirrors: [URL] }

    static func run(target: URL,
                    isCancelled: () -> Bool = { false },
                    onProgress: (VerifyProgress) -> Void = { _ in }) -> HealReport? {
        // Load manifests oldest→newest; newest-wins per resolved file path.
        var loaded: [(createdAt: Date, urlPath: String, root: URL, mirrors: [URL], files: [ManifestEntry])] = []
        for manifestURL in ManifestWriter.manifestURLs(near: target) {
            guard let data = try? Data(contentsOf: manifestURL), let m = ManifestWriter.decode(data) else { continue }
            let root = manifestURL.deletingLastPathComponent().deletingLastPathComponent()
            // Recorded destinations (primary at 0, then mirrors); fall back for
            // manifests written before the `destinations` field.
            let recorded = m.destinations ?? ([m.primaryDestination] + (m.archiveDestination.map { [$0] } ?? []))
            let mirrors = recorded.dropFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
            loaded.append((m.createdAt, manifestURL.path, root, mirrors, m.files))
        }
        loaded.sort { ($0.createdAt, $0.urlPath) < ($1.createdAt, $1.urlPath) }

        var byPath: [String: Item] = [:]
        for record in loaded {
            for entry in record.files {
                guard let hex = entry.xxhash64, let expected = UInt64(hex, radix: 16) else { continue }
                let fileURL = record.root.appendingPathComponent(entry.path)
                byPath[fileURL.path] = Item(rel: entry.path, expected: expected,
                                            primaryRoot: record.root, mirrors: record.mirrors)
            }
        }
        let items = byPath.values.sorted { $0.rel < $1.rel }

        var healthy = 0
        var candidates: [HealCandidate] = []
        for (i, item) in items.enumerated() {
            if isCancelled() { return nil }
            let primaryURL = item.primaryRoot.appendingPathComponent(item.rel)
            let exists = FileManager.default.fileExists(atPath: primaryURL.path)
            let primaryOK = exists && hash(primaryURL) == item.expected

            if primaryOK {
                healthy += 1
            } else {
                let source = item.mirrors
                    .map { $0.appendingPathComponent(item.rel) }
                    .first { FileManager.default.fileExists(atPath: $0.path) && hash($0) == item.expected }
                candidates.append(HealCandidate(
                    relPath: item.rel,
                    kind: exists ? .changed : .missing,
                    badPath: primaryURL.path(percentEncoded: false),
                    recoverableFrom: source?.path(percentEncoded: false)
                ))
            }
            onProgress(VerifyProgress(total: items.count, checked: i + 1,
                                     currentFile: (item.rel as NSString).lastPathComponent))
        }
        return HealReport(healthy: healthy, candidates: candidates, manifestCount: loaded.count)
    }

    /// A reviewable restore script for the recoverable candidates. PhotoDrop never
    /// runs it — the user inspects and executes it deliberately.
    static func restoreScript(_ report: HealReport) -> String {
        var lines = [
            "#!/bin/sh",
            "# PhotoDrop restore script — REVIEW before running.",
            "# Restores damaged/missing files from a verified mirror copy.",
            "",
        ]
        for c in report.recoverable {
            guard let from = c.recoverableFrom else { continue }
            let dir = (c.badPath as NSString).deletingLastPathComponent
            lines.append("mkdir -p \(quote(dir)) && cp -p \(quote(from)) \(quote(c.badPath))   # \(c.relPath)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func hash(_ url: URL) -> UInt64? {
        try? XxHash64.hash(fileAt: url, bypassCache: true)
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
