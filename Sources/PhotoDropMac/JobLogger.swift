import Foundation

enum JobLogger {
    // Writes a plaintext log of the ingest to ~/Library/Logs/PhotoDrop/
    // Filename: ingest-<sortable-timestamp>.log. Returns the log URL on
    // success, nil on failure (unwritable directory, etc.). Non-fatal —
    // the copy result itself is not blocked on logging.
    static func write(
        entries: [LogEntry],
        startedAt: Date,
        elapsedSeconds: Double,
        primaryDestination: URL,
        archiveDestination: URL?
    ) -> URL? {
        let fm = FileManager.default
        guard let libraryDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let logDir = libraryDir
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("PhotoDrop", isDirectory: true)

        do {
            try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let fileStampFormatter = DateFormatter()
        fileStampFormatter.locale = Locale(identifier: "en_US_POSIX")
        fileStampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let fileStamp = fileStampFormatter.string(from: startedAt)
        let logURL = logDir.appendingPathComponent("ingest-\(fileStamp).log")

        let lineStampFormatter = DateFormatter()
        lineStampFormatter.locale = Locale(identifier: "en_US_POSIX")
        lineStampFormatter.dateFormat = "HH:mm:ss.SSS"

        var content = "PhotoDrop ingest log\n"
        content += "Started:  \(startedAt.formatted(.iso8601))\n"
        content += "Elapsed:  \(String(format: "%.1fs", elapsedSeconds))\n"
        content += "Primary:  \(primaryDestination.path(percentEncoded: false))\n"
        if let archiveDestination {
            content += "Archive:  \(archiveDestination.path(percentEncoded: false))\n"
        }
        content += String(repeating: "-", count: 64) + "\n"

        for entry in entries {
            let ts = lineStampFormatter.string(from: entry.timestamp)
            let kind = entry.kind.label.padding(toLength: 8, withPad: " ", startingAt: 0)
            content += "\(ts)  \(kind)  \(entry.line)\n"
        }

        do {
            try content.write(to: logURL, atomically: true, encoding: .utf8)
            return logURL
        } catch {
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
