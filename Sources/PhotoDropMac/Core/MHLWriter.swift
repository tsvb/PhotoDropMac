import Foundation

/// Writes a Media Hash List (MHL) alongside PhotoDrop's own manifest.
///
/// **Why a second format.** The JSON/CSV manifest is the record of truth and is
/// read by `verify`, `heal` and `sync` — but only PhotoDrop can read it. MHL is
/// the ASC-blessed XML that Hedge, OffShoot, Silverstack and ShotPut Pro all
/// emit and that post houses and delivery specs actually require. A receipt
/// nobody else can read is a receipt you cannot hand to anyone, which matters
/// exactly as soon as the card has video on it — and the hybrid shooter is the
/// same person either way.
///
/// **Secondary, like the checksum xattr.** MHL is written best-effort and is
/// never read back: `verify` and `heal` continue to derive everything from the
/// JSON manifest, which is where the schema check, the containment rule and the
/// conflict rule live. A failure to write it never fails a job.
///
/// The digest element is `<xxhash64be>`, which is what the MHL spec names for a
/// big-endian XXH64 — the same 16 hex digits `%016llx` already produces for the
/// manifest, so nothing is recomputed and the two records cannot disagree.
enum MHLWriter {

    /// Renders `manifest` as MHL XML.
    ///
    /// Entries whose digest is absent are **omitted**, not written with an empty
    /// hash: an MHL entry exists to assert a checksum, and one asserting nothing
    /// would be read by another tool as a file it had verified.
    static func render(_ manifest: Manifest, hostname: String = ProcessInfo.processInfo.hostName,
                       username: String = NSUserName()) -> String {
        let created = iso8601String(from: manifest.createdAt)
        let finished = iso8601String(
            from: manifest.createdAt.addingTimeInterval(manifest.elapsedSeconds))

        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="1.1">
          <creatorinfo>
            <name>\(escape(username))</name>
            <username>\(escape(username))</username>
            <hostname>\(escape(hostname))</hostname>
            <tool>\(escape(Manifest.appName))</tool>
            <startdate>\(created)</startdate>
            <finishdate>\(finished)</finishdate>
          </creatorinfo>

        """

        for entry in manifest.files {
            guard let digest = entry.xxhash64, !digest.isEmpty else { continue }
            out += """
              <hash>
                <file>\(escape(entry.path))</file>
                <size>\(entry.bytes)</size>
                <xxhash64be>\(escape(digest))</xxhash64be>
                <hashdate>\(created)</hashdate>
              </hash>

            """
        }

        out += "</hashlist>\n"
        return out
    }

    /// Writes `<base>.mhl` next to an already-claimed manifest.
    ///
    /// Takes the JSON's *resolved* base for the same reason the CSV does: a
    /// manifest that had to take a `-2` collision suffix must not be paired with
    /// an unsuffixed sibling naming a different job.
    @discardableResult
    static func write(_ manifest: Manifest, into directory: URL, base: String) -> URL? {
        guard let data = render(manifest).data(using: .utf8),
              let url = JobStamp.claimUniqueName(in: directory, base: base, pathExtension: "mhl")
        else { return nil }
        guard (try? data.write(to: url, options: .atomic)) != nil else {
            try? FileManager.default.removeItem(at: url)   // don't leave the empty claim behind
            return nil
        }
        return url
    }

    /// XML text escaping.
    ///
    /// **A filename is untrusted text**, and this is a sink that renders it —
    /// the same category as `CLIOutput.safe`, `JobLogger` and `HealEngine`'s
    /// shell comments, which is why the rule is applied here rather than assumed.
    /// A file named `a<b&c".CR2` is legal on every filesystem PhotoDrop writes
    /// to, and unescaped it produces XML another tool either rejects or, worse,
    /// misparses into a different path than the one that was copied.
    ///
    /// Unlike the terminal and log sinks this does **not** strip control
    /// characters: XML 1.0 forbids most of them outright, so a name containing
    /// one cannot be represented at all. They are dropped rather than escaped,
    /// and the JSON manifest — which stores the name the file actually has —
    /// remains the authority.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&apos;"
            default:
                // XML 1.0 legal range, minus the C0 controls other than tab,
                // newline and carriage return.
                let v = scalar.value
                let legal = v == 0x9 || v == 0xA || v == 0xD
                    || (v >= 0x20 && v <= 0xD7FF)
                    || (v >= 0xE000 && v <= 0xFFFD)
                    || (v >= 0x10000 && v <= 0x10FFFF)
                if legal { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// A fresh formatter per call rather than a shared one.
    ///
    /// `ISO8601DateFormatter` is not `Sendable`, and this type is called from the
    /// nonisolated engine. Construction cost is irrelevant here — it happens
    /// twice per job, not per file, unlike the date patterns `TemplateRenderer`
    /// caches precisely because they *are* per file.
    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
