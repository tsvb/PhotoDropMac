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
                // Untrusted path: dropped outright if it escapes the library root.
                // Without this, a manifest `path` of `../../..` makes the restore
                // script below emit a `cp` that overwrites a file outside the
                // library entirely. See `ManifestWriter.resolve`.
                guard let fileURL = ManifestWriter.resolve(entryPath: entry.path, under: record.root) else { continue }
                byPath[fileURL.path] = Item(rel: entry.path, expected: expected,
                                            primaryRoot: record.root, mirrors: record.mirrors)
            }
        }
        let items = byPath.values.sorted { $0.rel < $1.rel }

        var healthy = 0
        var candidates: [HealCandidate] = []
        for (i, item) in items.enumerated() {
            if isCancelled() { return nil }
            guard let primaryURL = ManifestWriter.resolve(entryPath: item.rel, under: item.primaryRoot) else { continue }
            let exists = FileManager.default.fileExists(atPath: primaryURL.path)
            let primaryOK = exists && hash(primaryURL) == item.expected

            if primaryOK {
                healthy += 1
            } else {
                // The mirror side is untrusted twice over: the mirror *root* comes
                // from the manifest's `destinations`, and the relative path from
                // its `path`. Containment keeps the recorded path from escaping
                // the recorded root; `restoreScript` additionally refuses to copy
                // from a root the user has not vouched for.
                let source = item.mirrors
                    .compactMap { ManifestWriter.resolve(entryPath: item.rel, under: $0) }
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
    ///
    /// The script header lists every directory the copies will read *from*. Those
    /// roots come from the manifest's `destinations`, which is untrusted data: a
    /// crafted manifest can name any readable path as a "mirror" and thereby feed
    /// attacker-chosen bytes into the library. Containment in `run` keeps the
    /// write side inside the library, and surfacing the read side here is what
    /// makes "REVIEW before running" a check the user can actually perform —
    /// an unfamiliar source root is the tell.
    static func restoreScript(_ report: HealReport) -> String {
        let recoverable = report.recoverable
        let sourceRoots = Set(recoverable.compactMap { $0.recoverableFrom.map { ($0 as NSString).deletingLastPathComponent } })

        var lines = [
            "#!/bin/sh",
            "# PhotoDrop restore script — REVIEW before running.",
            "# Restores damaged/missing files from a verified mirror copy.",
            "#",
            "# Files will be copied FROM these directories — confirm you recognize",
            "# every one of them before running this script:",
        ]
        lines += sourceRoots.sorted().map { "#   \(comment($0))" }
        lines += [
            "",
            "set -eu",
            "",
        ]
        for c in recoverable {
            guard let from = c.recoverableFrom else { continue }
            let dir = (c.badPath as NSString).deletingLastPathComponent

            // A path holding control characters is still *correctly* quoted below
            // — a newline inside '…' is literal to the shell — but it would wreck
            // the review this script's safety rests on. The path's remainder
            // renders as its own line, so a card file named `IMG⏎rm -rf $HOME⏎#`
            // puts an apparent `rm -rf $HOME` command in front of the reviewer
            // with nothing on screen to show it is inert. (Interior newlines
            // survive `PathPlanner.sanitize`, which only trims the ends, so this
            // is reachable from a card.) Emit these commented out instead, and
            // keep the invariant that every executable line is a generated
            // mkdir/cp pair.
            guard ![dir, from, c.badPath].contains(where: hasControlCharacters) else {
                lines.append("# SKIPPED — control characters in path; restore this one by hand:")
                lines.append("#   from: \(comment(from))")
                lines.append("#   to:   \(comment(c.badPath))")
                continue
            }

            lines.append("mkdir -p \(quote(dir)) && cp -p \(quote(from)) \(quote(c.badPath))   # \(comment(c.relPath))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func hash(_ url: URL) -> UInt64? {
        try? XxHash64.hash(fileAt: url, bypassCache: true)
    }

    /// POSIX single-quote escaping: the only character with meaning inside `'…'`
    /// is `'` itself, so closing, escaping, and reopening the quote renders any
    /// byte string inert.
    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func hasControlCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Renders untrusted text safe to sit in a `#` comment.
    ///
    /// A shell comment ends at the first newline, so an unescaped newline here
    /// would turn the rest of the value into executable script lines. That is
    /// reachable from a card: `PathPlanner.sanitize` trims whitespace only at the
    /// ends of a name, so a file named `IMG⏎rm -rf ~⏎#.DNG` carries its interior
    /// newlines all the way into the manifest and out to this comment. Control
    /// characters are escaped rather than dropped so the comment still tells the
    /// user what the odd filename actually contains.
    private static func comment(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // C0 controls and DEL — includes ESC, which would otherwise let a
                // filename rewrite the terminal when the script is `cat`ed.
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
