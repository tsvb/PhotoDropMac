import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Presents a library re-verification: live progress while re-hashing, then a
/// report of what matched / changed / went missing.
struct VerifySheet: View {
    let verifier: Verifier
    let onDismiss: () -> Void

    @AppStorage("photodrop.verificationStyle") private var theme = VerificationStyle.steady

    var body: some View {
        VStack(spacing: 20) {
            switch verifier.state {
            case .idle, .running:
                runningView
            case .completed(let report):
                reportView(report)
            case .failed(let message):
                failedView(message)
            }
        }
        .padding(28)
        .frame(width: 520)
        .tint(theme.accent)
    }

    // MARK: Running

    @ViewBuilder
    private var runningView: some View {
        let progress: VerifyProgress = {
            if case .running(let p) = verifier.state { return p }
            return VerifyProgress(total: 0, checked: 0, currentFile: "")
        }()

        Image(systemName: "shield.lefthalf.filled")
            .font(.system(size: 40))
            .foregroundStyle(.tint)

        Text("Verifying library")
            .font(.title2.weight(.semibold))

        if progress.total > 0 {
            ProgressView(value: progress.fraction)
                .frame(maxWidth: 360)
            Text("Checked \(progress.checked) of \(progress.total)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(progress.currentFile)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360)
        } else {
            ProgressView()
            Text(progress.currentFile.isEmpty ? "Reading manifests…" : progress.currentFile)
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        Button("Cancel", role: .cancel) {
            verifier.cancel()
            onDismiss()
        }
    }

    // MARK: Report

    @ViewBuilder
    private func reportView(_ report: VerifyReport) -> some View {
        if report.allGood {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Library verified")
                .font(.title2.weight(.semibold))
            Text("All \(report.verified) file\(report.verified == 1 ? "" : "s") match their recorded checksum.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
                .symbolRenderingMode(.hierarchical)
            Text("Verification found issues")
                .font(.title2.weight(.semibold))
            Text(summaryLine(report))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            issueList(report.issues)
        }

        Button("Done", action: onDismiss)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
    }

    private func summaryLine(_ report: VerifyReport) -> String {
        var parts = ["\(report.verified) verified"]
        if report.changed > 0 { parts.append("\(report.changed) changed") }
        if report.missing > 0 { parts.append("\(report.missing) missing") }
        if report.unreadable > 0 { parts.append("\(report.unreadable) unreadable") }
        if report.conflicts > 0 { parts.append("\(report.conflicts) conflicting") }
        return parts.joined(separator: " · ")
    }

    private func issueList(_ issues: [VerifyIssue]) -> some View {
        let shown = Array(issues.prefix(200))
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(shown) { issue in
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: issue.kind))
                                .foregroundStyle(color(for: issue.kind))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(issue.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(issue.path)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Text(label(for: issue.kind))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(color(for: issue.kind))
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 240)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                if issues.count > shown.count {
                    Text("+ \(issues.count - shown.count) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // The report was non-selectable `Text` in a sheet that
                // `Verifier.reset()` empties on dismiss, with no export — so the
                // app's answer to a library with 3,000 changed files was a
                // scrollable list of the first 200 names that could not leave the
                // window. Re-running means re-hashing the whole library.
                Button("Copy List") { copyIssues(issues) }
                    .controlSize(.small)
                Button("Save Report…") { saveIssues(issues) }
                    .controlSize(.small)
            }
            .padding(.top, 6)
        }
        .textSelection(.enabled)
    }

    /// Plain text: it pastes into a note, an email or an issue unchanged.
    private func issueText(_ issues: [VerifyIssue]) -> String {
        issues.map { "\(label(for: $0.kind))\t\($0.path)" }.joined(separator: "\n") + "\n"
    }

    private func copyIssues(_ issues: [VerifyIssue]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(issueText(issues), forType: .string)
    }

    private func saveIssues(_ issues: [VerifyIssue]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "verify-report.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.title = "Save Verification Report"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? issueText(issues).data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: Failed / empty

    @ViewBuilder
    private func failedView(_ message: String) -> some View {
        Image(systemName: "questionmark.folder")
            .font(.system(size: 40))
            .foregroundStyle(.secondary)
        Text("Nothing could be checked")
            .font(.title2.weight(.semibold))
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        Button("Done", action: onDismiss)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
    }

    private func icon(for kind: VerifyIssue.Kind) -> String {
        switch kind {
        case .changed:    return "exclamationmark.triangle.fill"
        case .missing:    return "xmark.circle.fill"
        case .unreadable: return "exclamationmark.octagon.fill"
        case .conflict:   return "questionmark.diamond.fill"
        }
    }

    private func color(for kind: VerifyIssue.Kind) -> Color {
        switch kind {
        case .changed:    return .orange
        case .missing:    return .red
        case .unreadable: return .red
        case .conflict:   return .red
        }
    }

    private func label(for kind: VerifyIssue.Kind) -> String {
        switch kind {
        case .changed:    return "CHANGED"
        case .missing:    return "MISSING"
        case .unreadable: return "UNREADABLE"
        case .conflict:   return "CONFLICT"
        }
    }
}
