import Foundation

enum JobLogger {
    /// `~/Library/Logs/PhotoDrop` — where a real job's log belongs.
    ///
    /// Injectable (see `write(… directory:)`) because this folder is the user's
    /// audit trail for what happened to their photos, and a test run that writes
    /// into it is indistinguishable from a real ingest. Measured before the
    /// parameter existed: one `xcodebuild test` deposited 18 `ingest-*.log` files
    /// there. That is an integrity problem, not a tidiness one.
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("PhotoDrop", isDirectory: true)
    }

    // Writes a plaintext log of the ingest to ~/Library/Logs/PhotoDrop/
    // Filename: ingest-<sortable-timestamp>.log. Returns the log URL on
    // success, nil on failure (unwritable directory, etc.). Non-fatal —
    // the copy result itself is not blocked on logging.
    /// `baseName` is the manifest's *resolved* filename stem, so the log lands
    /// beside it under the same name even when the manifest had to take a
    /// collision suffix. Pass nil (no manifest was written) and the log derives
    /// its own stem from `startedAt`.
    ///
    /// Pairing is best-effort by design: manifests live per-destination while
    /// logs share one global folder, so two concurrent jobs to *different*
    /// libraries can collide here and not there, leaving one log with a suffix
    /// its manifest doesn't have. The manifest name is the authoritative one; a
    /// cosmetic mismatch beats overwriting somebody's log.
    static func write(
        entries: [LogEntry],
        startedAt: Date,
        elapsedSeconds: Double,
        primaryDestination: URL,
        archiveDestinations: [URL],
        baseName: String? = nil,
        directory: URL? = nil
    ) -> URL? {
        let fm = FileManager.default
        guard let logDir = directory ?? defaultDirectory else { return nil }

        do {
            try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        // Same stamp source as the manifest, so the two pair up by filename, and
        // claimed with O_EXCL so a concurrent job can't overwrite this log.
        let base = baseName ?? "ingest-\(JobStamp.fileStamp(startedAt))"
        guard let logURL = JobStamp.claimUniqueName(in: logDir, base: base, pathExtension: "log") else {
            return nil
        }

        let lineStampFormatter = DateFormatter()
        lineStampFormatter.locale = Locale(identifier: "en_US_POSIX")
        lineStampFormatter.dateFormat = "HH:mm:ss.SSS"

        var content = "PhotoDrop ingest log\n"
        content += "Started:  \(startedAt.formatted(.iso8601))\n"
        content += "Elapsed:  \(String(format: "%.1fs", elapsedSeconds))\n"
        content += "Primary:  \(primaryDestination.path(percentEncoded: false))\n"
        for (i, archive) in archiveDestinations.enumerated() {
            let label = archiveDestinations.count > 1 ? "Archive \(i + 1)" : "Archive"
            content += "\(label):  \(archive.path(percentEncoded: false))\n"
        }
        content += String(repeating: "-", count: 64) + "\n"

        for entry in entries {
            let ts = lineStampFormatter.string(from: entry.timestamp)
            let kind = entry.kind.label.padding(toLength: 8, withPad: " ", startingAt: 0)
            // Keep the full 16-char hash in the on-disk log even though the UI
            // now renders a compact signature from `entry.signature`.
            // The line carries card-authored filenames verbatim, and this file is
            // what the user reads afterwards to reconstruct what happened to
            // their photos. Confirmed against a real log: a file named
            // `IMG\u{1B}[2K\u{1B}[1A0002.CR2` erased the preceding VERIFY line
            // when the log was `cat`ed, and a raw newline in a name forged an
            // entire fabricated record — right kind, right timestamp shape.
            // `CLIOutput.safe` and `HealEngine.comment` already guarded their
            // sinks; this was the one that was missed, and it is the durable one.
            var lineText = SafeText.display(entry.line)
            if let signature = entry.signature {
                lineText += "  [\(String(format: "%016llx", signature))]"
            }
            content += "\(ts)  \(kind)  \(lineText)\n"
        }

        do {
            try content.write(to: logURL, atomically: true, encoding: .utf8)
            return logURL
        } catch {
            try? FileManager.default.removeItem(at: logURL)   // don't leave the empty claim behind
            return nil
        }
    }
}

extension LogEntry.Kind {
    var label: String {
        switch self {
        case .info:     return "INFO"
        case .copied:   return "COPY"
        case .skipped:  return "SKIP"
        case .verified: return "VERIFY"
        case .error:    return "ERROR"
        }
    }
}
