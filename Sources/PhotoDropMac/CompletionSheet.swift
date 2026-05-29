import SwiftUI
import AppKit

struct CompletionSheet: View {
    let result: CopyResult
    let onDismiss: () -> Void

    @AppStorage("photodrop.verificationStyle") private var verificationStyle = VerificationStyle.steady

    var body: some View {
        VStack(spacing: 20) {
            if hadIssues {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.hierarchical)
            } else {
                // Success hero — the mark depends on the verification style.
                switch verificationStyle {
                case .ledger:
                    StampMark(progress: 1, stamped: true)
                        .frame(width: 72, height: 72)
                case .pressroom:
                    ApertureMark(progress: 1, closed: true)
                        .frame(width: 72, height: 72)
                case .steady:
                    SealGrid(progress: 1, pulse: true)
                        .frame(width: 56, height: 56)
                }
            }

            VStack(spacing: 4) {
                Text(verificationStyle == .pressroom ? title.uppercased() : title)
                    .font(titleFont)
                    .tracking(verificationStyle == .pressroom ? 2 : 0)
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
        .tint(verificationStyle.accent)
    }

    private var hadIssues: Bool { result.filesFailed > 0 }

    // Ledger swaps the SF Pro semibold headline for a regular-weight system
    // serif (New York) — the "single moment of typographic warmth".
    private var titleFont: Font {
        switch verificationStyle {
        case .ledger:    return .system(.title, design: .serif)
        case .pressroom: return .system(.title3, design: .monospaced).weight(.bold)
        case .steady:    return .title2.weight(.semibold)
        }
    }

    private var title: String {
        if hadIssues {
            return "Ingest completed with errors"
        }
        return "Ingest complete"
    }

    private var subtitle: String {
        // Failure leads with the failed count and omits the eject line — the
        // user needs to retry from the card.
        if result.filesFailed > 0 {
            let n = result.filesFailed
            return "\(n) file\(n == 1 ? "" : "s") failed — see log for details."
        }

        var base: String
        if result.filesCopied == 0, result.filesSkipped > 0 {
            base = "Everything was already there — nothing new to copy."
        } else if result.filesCopied > 0, result.filesSkipped > 0 {
            base = "\(result.filesCopied) copied, \(result.filesSkipped) already present."
        } else if result.filesCopied > 0 {
            base = "All files copied and verified."
        } else {
            base = "Ingest complete."
        }

        if result.wasEjected {
            base += " Card ejected — safe to remove."
        }
        return base
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

private func previewResult(copied: Int, skipped: Int, failed: Int, ejected: Bool, log: Bool) -> CopyResult {
    CopyResult(
        bundleCount: copied + skipped + failed,
        filesCopied: copied, filesSkipped: skipped, filesFailed: failed,
        totalBytes: 26_400_000_000, elapsedSeconds: 642,
        primaryDestination: URL(fileURLWithPath: "/Users/you/Pictures/Library"),
        logURL: log ? URL(fileURLWithPath: "/tmp/ingest.log") : nil,
        wasEjected: ejected, halted: false, haltReason: nil
    )
}

#Preview("Complete — clean") {
    CompletionSheet(result: previewResult(copied: 482, skipped: 0, failed: 0, ejected: true, log: true), onDismiss: {})
}

#Preview("Complete — with skips") {
    CompletionSheet(result: previewResult(copied: 120, skipped: 362, failed: 0, ejected: true, log: true), onDismiss: {})
}

#Preview("Complete — only dupes") {
    CompletionSheet(result: previewResult(copied: 0, skipped: 482, failed: 0, ejected: true, log: false), onDismiss: {})
}

#Preview("Complete — with errors") {
    CompletionSheet(result: previewResult(copied: 480, skipped: 0, failed: 2, ejected: false, log: true), onDismiss: {})
}
