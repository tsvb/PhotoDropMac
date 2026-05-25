import SwiftUI
import AppKit

struct CompletionSheet: View {
    let result: CopyResult
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            if hadIssues {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.hierarchical)
            } else {
                SealGrid(progress: 1, pulse: true)
                    .frame(width: 56, height: 56)
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            stats
                .padding(.vertical, 6)

            HStack(spacing: 10) {
                if let logURL = result.logURL {
                    Button("Open Log") {
                        NSWorkspace.shared.open(logURL)
                    }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.primaryDestination])
                }
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(minWidth: 440, idealWidth: 480)
    }

    private var hadIssues: Bool { result.filesFailed > 0 }

    private var title: String {
        if hadIssues {
            return "Ingest completed with errors"
        }
        return "Ingest complete"
    }

    private var subtitle: String {
        let base = baseSummary
        if result.wasEjected {
            return "\(base) Card ejected — safe to remove."
        }
        return base
    }

    private var baseSummary: String {
        if result.filesFailed > 0 {
            return "Some files failed — see log for details."
        } else if result.filesCopied == 0, result.filesSkipped > 0 {
            return "Everything was already there — nothing new to copy."
        } else if result.filesCopied > 0, result.filesSkipped > 0 {
            return "\(result.filesCopied) copied, \(result.filesSkipped) already present."
        } else if result.filesCopied > 0 {
            return "All files copied and verified."
        } else {
            return "Ingest complete."
        }
    }

    @ViewBuilder
    private var stats: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Files").foregroundStyle(.secondary)
                Text(filesLine).monospacedDigit()
            }
            GridRow {
                Text("Size").foregroundStyle(.secondary)
                Text(result.totalBytes.formatted(.byteCount(style: .file))).monospacedDigit()
            }
            GridRow {
                Text("Elapsed").foregroundStyle(.secondary)
                Text(elapsedText).monospacedDigit()
            }
            GridRow {
                Text("Speed").foregroundStyle(.secondary)
                Text(speedText).monospacedDigit()
            }
        }
        .font(.callout)
    }

    private var filesLine: String {
        var parts = ["\(result.filesCopied) copied"]
        if result.filesSkipped > 0 {
            parts.append("\(result.filesSkipped) skipped")
        }
        if result.filesFailed > 0 {
            parts.append("\(result.filesFailed) failed")
        }
        return parts.joined(separator: ", ")
    }

    private var elapsedText: String {
        let total = Int(result.elapsedSeconds)
        let mins = total / 60
        let secs = total % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(result.elapsedSeconds.formatted(.number.precision(.fractionLength(1))))s"
    }

    private var speedText: String {
        guard result.elapsedSeconds > 0 else { return "—" }
        let mib = Double(result.totalBytes) / result.elapsedSeconds / (1024 * 1024)
        return "\(mib.formatted(.number.precision(.fractionLength(1)))) MB/s"
    }
}
