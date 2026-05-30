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
    let verified: Bool        // whether xxHash verification was on for this job
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

        let base = "ingest-\(fileStamp(stamp))"
        let jsonURL = dir.appendingPathComponent(base + ".json")
        let csvURL = dir.appendingPathComponent(base + ".csv")

        guard let json = encodeJSON(manifest) else { return nil }
        do {
            try json.write(to: jsonURL, options: .atomic)
            if let csvData = csv(manifest).data(using: .utf8) {
                try csvData.write(to: csvURL, options: .atomic)
            }
            return jsonURL
        } catch {
            return nil
        }
    }

    static func encodeJSON(_ manifest: Manifest) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(manifest)
    }

    static func decode(_ data: Data) -> Manifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
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

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
