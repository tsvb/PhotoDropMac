import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CompletionSheet: View {
    let result: CopyResult
    let onDismiss: () -> Void

    @AppStorage("photodrop.verificationStyle") private var verificationStyle = VerificationStyle.steady
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 20) {
            if withheldSeal {
                Image(systemName: hadIssues ? "exclamationmark.octagon.fill" : "seal.slash.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.hierarchical)
            } else {
                // Success hero — the mark depends on the verification style.
                switch verificationStyle {
                case .ledger:
                    StampMark(progress: 1, stamped: true, accent: verificationStyle.resolvedAccent)
                        .frame(width: 72, height: 72)
                case .pressroom:
                    ApertureMark(progress: 1, closed: true, accent: verificationStyle.resolvedAccent)
                        .frame(width: 72, height: 72)
                case .steady:
                    SealGrid(progress: 1, pulse: true, accent: verificationStyle.resolvedAccent)
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
                if let manifestURL = result.manifestURL {
                    Button("Export Manifest…") { exportManifest(manifestURL) }
                }
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(minWidth: 440, idealWidth: 480)
        .tint(verificationStyle.accent)
        .alert("Couldn’t export the manifest", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// The alarm hero is for the *library* being incomplete. A mirror that
    /// failed while the primary landed cleanly is a real problem worth telling
    /// the user about — see `subtitle` — but it is not the same event, and
    /// showing the same red octagon for both taught the user to distrust it.
    private var hadIssues: Bool { result.primaryFailures > 0 }

    /// The hero mark is withheld for a missing manifest too. A verification seal
    /// over a job that produced no verification record is the one image this app
    /// must never show.
    private var withheldSeal: Bool { hadIssues || !result.manifestFailures.isEmpty }

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
        // A missing manifest is its own headline. The files are on disk and
        // every byte was verified in flight, so "with errors" would overstate
        // it — but "Ingest complete" understates a library that nothing can
        // ever re-verify, which is the whole product. Say exactly what happened.
        if !result.manifestFailures.isEmpty {
            return "Copied — but the receipt could not be written"
        }
        if !result.failedMirrors.isEmpty {
            return "Library complete — a mirror fell behind"
        }
        return "Ingest complete"
    }

    private var subtitle: String {
        // Failure leads with the failed count and omits the eject line — the
        // user needs to retry from the card.
        if result.primaryFailures > 0 {
            let n = result.primaryFailures
            var s = "\(n) file\(n == 1 ? "" : "s") failed — see log for details."
            if !result.failedMirrors.isEmpty { s += " \(mirrorFailureSentence)" }
            return s
        }
        if !result.manifestFailures.isEmpty {
            let names = result.manifestFailures.map { ($0 as NSString).lastPathComponent }
            let list = names.count == 1 ? "“\(names[0])”" : names.map { "“\($0)”" }.joined(separator: ", ")
            var s = "Every file was copied and verified, but the checksum manifest could not be "
                  + "saved to \(list), so “Verify Library” has nothing to check there. "
                  + "Check the folder is writable and has free space, then re-run the ingest."
            if !result.failedMirrors.isEmpty { s += " \(mirrorFailureSentence)" }
            return s
        }
        // The primary is complete; say so plainly before naming the mirror, so
        // the user knows their photos are safe.
        if !result.failedMirrors.isEmpty {
            return "Every file landed in your primary library. \(mirrorFailureSentence)"
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

    private var mirrorFailureSentence: String {
        let names = result.failedMirrors.map { ($0 as NSString).lastPathComponent }
        let list = names.count == 1 ? "“\(names[0])”" : names.map { "“\($0)”" }.joined(separator: ", ")
        return "Could not write to \(list) — re-run the ingest to bring \(names.count == 1 ? "it" : "them") up to date."
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

    // The manifest is already written next to the photos; this saves a copy
    // wherever the user wants (e.g. to send a receipt with a delivery).
    private func exportManifest(_ manifestURL: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = manifestURL.lastPathComponent
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = "Export Verification Manifest"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let fm = FileManager.default
        do {
            // The save panel already confirmed any overwrite; replace the target.
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: manifestURL, to: destination)
        } catch {
            // Surface the failure instead of swallowing it — the user thinks a
            // receipt was saved otherwise.
            exportError = error.localizedDescription
        }
    }
}

private func previewResult(copied: Int, skipped: Int, failed: Int, ejected: Bool, log: Bool) -> CopyResult {
    CopyResult(
        bundleCount: copied + skipped + failed,
        filesCopied: copied, filesSkipped: skipped, filesFailed: failed,
        failuresByDestination: failed > 0 ? ["/Users/you/Pictures/Library": failed] : [:],
        totalBytes: 26_400_000_000, elapsedSeconds: 642,
        primaryDestination: URL(fileURLWithPath: "/Users/you/Pictures/Library"),
        logURL: log ? URL(fileURLWithPath: "/tmp/ingest.log") : nil,
        manifestURL: log ? URL(fileURLWithPath: "/tmp/ingest.json") : nil,
        manifestFailures: [],
        wasEjected: ejected, halted: false, haltReason: nil, cancelled: false
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
