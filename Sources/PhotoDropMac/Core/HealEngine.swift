import Foundation

struct HealCandidate: Sendable, Equatable {
    /// `conflicted` means the library's own manifests record different digests
    /// for this file, so there is no expected value to heal *towards*. It is
    /// never recoverable — offering a restore would mean picking a winner among
    /// the disagreeing records, which is exactly the judgement no one can make.
    enum Kind: Sendable { case changed, missing, conflicted }
    let relPath: String
    let kind: Kind
    let badPath: String            // where the damaged/absent primary copy belongs
    let recoverableFrom: String?   // a verified mirror copy's path, or nil if none exists
}

struct HealReport: Sendable {
    let healthy: Int
    let candidates: [HealCandidate]
    let manifestCount: Int
    /// Recorded mirror roots that were not searched — see `VerifyEngine.build`.
    var refusedMirrorRoots: [String] = []

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
///
/// **What to expect of a file comes from `VerifyEngine.build` and nowhere else.**
/// Both engines read the same unauthenticated manifests out of a folder anyone
/// who can write to the library can add to, so they must apply the same trust
/// rule — and `build` is where that rule is stated and argued. This engine
/// previously kept its own oldest→newest merge that let the newest manifest win,
/// which is precisely the rule `build` documents as unsafe: planting one JSON
/// dated 2099 recording a tampered file's *current* digest made `heal` call the
/// corrupted library healthy while `verify` correctly flagged the conflict. Do
/// not reintroduce a second merge here; extend `build` if this needs more.
enum HealEngine {
    static func run(target: URL,
                    allowedMirrorRoots: [URL] = [],
                    isCancelled: () -> Bool = { false },
                    onProgress: (VerifyProgress) -> Void = { _ in }) -> HealReport? {
        let (items, manifestCount, conflicts, refusedMirrorRoots) =
            VerifyEngine.build(target: target, allowedMirrorRoots: allowedMirrorRoots)

        // Files whose manifests disagree are reported, never healed: with two
        // rival digests on record there is no expected value to restore towards.
        var candidates: [HealCandidate] = conflicts.map {
            HealCandidate(relPath: $0.path, kind: .conflicted,
                          badPath: $0.path, recoverableFrom: nil)
        }

        var healthy = 0
        let total = items.count + conflicts.count
        for (i, item) in items.enumerated() {
            if isCancelled() { return nil }
            let exists = FileManager.default.fileExists(atPath: item.url.path)
            let primaryOK = exists && hash(item.url) == item.expected

            if primaryOK {
                healthy += 1
            } else {
                // The mirror side is untrusted twice over: the mirror *root* comes
                // from the manifest's `destinations`, and the relative path from
                // its `path`. Containment keeps the recorded path from escaping
                // the recorded root; the hash check below means a root can only
                // ever be *offered* if it actually holds the expected bytes; and
                // `restoreScript` lists every source root so the user can refuse
                // one they don't recognize.
                let source = item.mirrors
                    .compactMap { ManifestWriter.resolve(entryPath: item.relPath, under: $0) }
                    .first { FileManager.default.fileExists(atPath: $0.path) && hash($0) == item.expected }
                candidates.append(HealCandidate(
                    relPath: item.relPath,
                    kind: exists ? .changed : .missing,
                    badPath: item.url.path(percentEncoded: false),
                    recoverableFrom: source?.path(percentEncoded: false)
                ))
            }
            onProgress(VerifyProgress(total: total, checked: i + 1,
                                     currentFile: (item.relPath as NSString).lastPathComponent))
        }
        return HealReport(healthy: healthy,
                          candidates: candidates.sorted { $0.relPath < $1.relPath },
                          manifestCount: manifestCount,
                          refusedMirrorRoots: refusedMirrorRoots)
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
            //
            // The test is `SafeText.containsDangerousControls`, which is wider
            // than the C0+DEL check this used to make: a bidi override defeats
            // the same review without being a control character at all. Measured
            // with the old check, a filename containing U+202E produced a **live**
            // `mkdir -p … && cp -p …` line — correctly quoted, and displayed to
            // the reviewer with its components reordered.
            guard ![dir, from, c.badPath].contains(where: SafeText.containsDangerousControls) else {
                lines.append("# SKIPPED — unreviewable characters in path; restore this one by hand:")
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

    /// Renders untrusted text safe to sit in a `#` comment.
    ///
    /// A shell comment ends at the first newline, so an unescaped newline here
    /// would turn the rest of the value into executable script lines. That is
    /// reachable from a card: `PathPlanner.sanitize` trims whitespace only at the
    /// ends of a name, so a file named `IMG⏎rm -rf ~⏎#.DNG` carries its interior
    /// newlines all the way into the manifest and out to this comment. Escaped
    /// rather than dropped, so the comment still tells the user what the odd
    /// filename actually contains — including that it holds an override.
    private static func comment(_ s: String) -> String { SafeText.display(s) }
}
