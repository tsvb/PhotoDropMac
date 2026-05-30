import ArgumentParser
import Foundation

@main
struct PhotoDropCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photodrop",
        abstract: "Verify and ingest photo libraries from the command line.",
        version: "0.0.1",
        subcommands: [Verify.self]
    )
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

    func run() throws {
        let url = URL(fileURLWithPath: target)
        let showProgress = !json && isatty(FileHandle.standardError.fileDescriptor) != 0

        let report = VerifyEngine.run(target: url, onProgress: { progress in
            guard showProgress else { return }
            FileHandle.standardError.write(Data("\r  verifying \(progress.checked)/\(progress.total)…".utf8))
        })
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }   // clear progress line

        guard let report else {
            CLIOutput.error("Verification was interrupted.")
            throw ExitCode(2)
        }
        guard report.total > 0 else {
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

    static func verifyHuman(_ r: VerifyReport) -> String {
        let scope = "\(r.total) file\(r.total == 1 ? "" : "s") across \(r.manifestCount) manifest\(r.manifestCount == 1 ? "" : "s")"
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
