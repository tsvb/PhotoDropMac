import ArgumentParser
import Foundation

@main
struct PhotoDropCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photodrop",
        abstract: "Verify and ingest photo libraries from the command line.",
        version: "0.0.1",
        subcommands: [Verify.self, Ingest.self]
    )
}

// MARK: - ingest

struct Ingest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ingest photos from a card into a date-organized library (hash-verified)."
    )

    @Option(name: .long, help: "Memory card or source folder to ingest from.")
    var from: String

    @Option(name: .long, help: "Primary destination library folder (or supplied by --preset).")
    var to: String?

    @Option(name: .long, help: "Additional mirror destination folder (repeatable).")
    var archive: [String] = []

    @Option(name: .long, help: "Apply a saved ingest preset by name.")
    var preset: String?

    @Flag(inversion: .prefixedNo, help: "Hash-verify each copy (default on).")
    var verify: Bool?

    @Flag(inversion: .prefixedNo, help: "Eject the card when finished (default off).")
    var eject: Bool?

    @Option(name: .customLong("description"), help: "Description used by the naming templates.")
    var descriptionText: String = ""

    @Option(name: .long, help: "Day-folder name template.")
    var folderTemplate: String?

    @Option(name: .long, help: "File-name stem template.")
    var fileTemplate: String?

    func run() async throws {
        let cardURL = URL(fileURLWithPath: from, isDirectory: true)

        let loadedPreset: IngestPreset?
        if let preset {
            loadedPreset = IngestPreset.loadAll(from: PresetStore.defaultURL).first { $0.name == preset }
            guard loadedPreset != nil else { CLIOutput.error("No preset named “\(preset)”."); throw ExitCode(2) }
        } else {
            loadedPreset = nil
        }

        guard let primaryPath = (to ?? loadedPreset?.primaryDestination).flatMap({ $0.isEmpty ? nil : $0 }) else {
            CLIOutput.error("A primary destination is required (--to or a preset that defines one).")
            throw ExitCode(2)
        }
        let primaryURL = URL(fileURLWithPath: primaryPath, isDirectory: true)

        let archiveURLs: [URL]
        if !archive.isEmpty {
            archiveURLs = archive.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else if let a = loadedPreset?.archiveDestination, !a.isEmpty {
            archiveURLs = [URL(fileURLWithPath: a, isDirectory: true)]
        } else {
            archiveURLs = []
        }

        let template = NamingTemplate(
            folder: folderTemplate ?? loadedPreset?.folderTemplate ?? NamingTemplate.default.folder,
            filename: fileTemplate ?? loadedPreset?.fileTemplate ?? NamingTemplate.default.filename
        )
        let doVerify = verify ?? loadedPreset?.verifyCopies ?? true
        let doEject = eject ?? loadedPreset?.ejectAfterIngest ?? false

        let bundles = AssetDiscovery.scan(root: cardURL)
        guard !bundles.isEmpty else {
            print("No recognized photos found on \(cardURL.path).")
            return
        }

        let volumeID = (try? cardURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? cardURL.path
        let cardLabel = (try? cardURL.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? cardURL.lastPathComponent
        let showProgress = isatty(FileHandle.standardError.fileDescriptor) != 0

        let engine = IngestEngine(
            bundles: bundles, description: descriptionText, primaryRoot: primaryURL,
            archiveRoots: archiveURLs, verify: doVerify, ejectAfter: doEject,
            sourceMountPoint: cardURL.path, sourceVolumeID: volumeID,
            template: template, cardLabel: cardLabel,
            cache: HashCache(storeURL: HashCache.defaultURL),
            indexStoreURL: DestinationIndex.defaultStoreURL,
            onProgress: { progress in
                guard showProgress else { return }
                let size = ByteCountFormatter.string(fromByteCount: progress.bytesCopied, countStyle: .file)
                FileHandle.standardError.write(Data("\r  \(progress.completedBundles)/\(progress.totalBundles) bundles · \(size)\u{1B}[K".utf8))
            }
        )
        let result = await engine.run()
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }

        guard let result else { CLIOutput.error("Ingest cancelled."); throw ExitCode(2) }
        print(CLIOutput.ingestSummary(result))
        if result.halted { throw ExitCode(2) }
        if result.filesFailed > 0 { throw ExitCode(1) }
    }
}

// MARK: - verify

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-verify a library (or a manifest .json) against its recorded checksums."
    )

    @Argument(help: "A library folder, its “PhotoDrop Manifests” folder, or a manifest .json.")
    var target: String

    @Flag(name: .long, help: "Emit a JSON report instead of human-readable text.")
    var json = false

    @Flag(name: .long, help: "Verify by each file's embedded checksum (xattr) instead of the manifest — works on any folder, even reorganized.")
    var xattr = false

    func run() throws {
        let url = URL(fileURLWithPath: target)
        let showProgress = !json && isatty(FileHandle.standardError.fileDescriptor) != 0
        let onProgress: (VerifyProgress) -> Void = { progress in
            guard showProgress else { return }
            FileHandle.standardError.write(Data("\r  verifying \(progress.checked)/\(progress.total)…".utf8))
        }

        let report = xattr
            ? VerifyEngine.runXattr(folder: url, onProgress: onProgress)
            : VerifyEngine.run(target: url, onProgress: onProgress)
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }   // clear progress line

        guard let report else {
            CLIOutput.error("Verification was interrupted.")
            throw ExitCode(2)
        }
        guard report.total > 0 else {
            if xattr {
                print("No checksummed (xattr) files found under \(url.path).")
                return   // nothing stamped is not an error
            }
            CLIOutput.error("No verification manifest found at \(url.path). Run an ingest first, or point at a folder containing a “\(ManifestWriter.folderName)” folder.")
            throw ExitCode(2)
        }

        print(json ? CLIOutput.verifyJSON(report) : CLIOutput.verifyHuman(report))
        if !report.allGood { throw ExitCode(1) }   // 0 = all good, 1 = issues found
    }
}

// MARK: - Output formatting

enum CLIOutput {
    static func error(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func ingestSummary(_ r: CopyResult) -> String {
        var parts = ["\(r.filesCopied) copied"]
        if r.filesSkipped > 0 { parts.append("\(r.filesSkipped) skipped") }
        if r.filesFailed > 0 { parts.append("\(r.filesFailed) failed") }
        let size = ByteCountFormatter.string(fromByteCount: r.totalBytes, countStyle: .file)
        let lead = r.halted ? "✗ Halted (\(r.haltReason ?? "error")): "
            : (r.filesFailed > 0 ? "⚠ Completed with errors: " : "✓ Ingest complete: ")
        var s = lead + parts.joined(separator: ", ") + " · " + size
        if let manifestURL = r.manifestURL { s += "\n  manifest: \(manifestURL.path)" }
        if r.wasEjected { s += "\n  card ejected" }
        return s
    }

    static func verifyHuman(_ r: VerifyReport) -> String {
        let files = "\(r.total) file\(r.total == 1 ? "" : "s")"
        let scope = r.manifestCount == 0   // xattr mode doesn't use manifests
            ? files
            : "\(files) across \(r.manifestCount) manifest\(r.manifestCount == 1 ? "" : "s")"
        guard !r.allGood else {
            return "✓ All \(scope) match their recorded checksums."
        }
        var lines = ["✗ \(r.verified) of \(scope) verified — \(r.changed) changed, \(r.missing) missing, \(r.unreadable) unreadable:"]
        for issue in r.issues {
            let tag: String
            switch issue.kind {
            case .changed:    tag = "CHANGED   "
            case .missing:    tag = "MISSING   "
            case .unreadable: tag = "UNREADABLE"
            }
            lines.append("  \(tag) \(issue.path)")
        }
        return lines.joined(separator: "\n")
    }

    static func verifyJSON(_ r: VerifyReport) -> String {
        struct IssueDTO: Encodable { let kind: String; let name: String; let path: String }
        struct ReportDTO: Encodable {
            let verified: Int, changed: Int, missing: Int, unreadable: Int
            let total: Int, manifestCount: Int, allGood: Bool
            let issues: [IssueDTO]
        }
        func kindString(_ k: VerifyIssue.Kind) -> String {
            switch k { case .changed: return "changed"; case .missing: return "missing"; case .unreadable: return "unreadable" }
        }
        let dto = ReportDTO(
            verified: r.verified, changed: r.changed, missing: r.missing, unreadable: r.unreadable,
            total: r.total, manifestCount: r.manifestCount, allGood: r.allGood,
            issues: r.issues.map { IssueDTO(kind: kindString($0.kind), name: $0.name, path: $0.path) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(dto)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
