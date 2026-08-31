import SwiftUI
import AppKit

/// The files a job could not copy, and why.
///
/// This exists because the app's entire account of a partial failure used to be
/// the sentence "40 files failed — see log for details". The reasons lived only
/// in `Copier.log`, which `DetailPane` stops rendering the moment a job leaves
/// `.running` and `Copier.reset()` empties on dismiss — so the moment the user
/// acknowledged the sheet, the evidence was gone and the only recourse was to
/// open a text file in TextEdit and read it by eye.
///
/// Selectable and copyable, because a failure a user cannot paste into a search
/// or a bug report is one they cannot act on.
struct FailureList: View {
    let failures: [CopyResult.FailedFile]
    /// The true failure count, which can exceed `failures.count` — the engine
    /// caps what it records. Stating both is the difference between a list and a
    /// claim about the list's completeness.
    let totalFailures: Int

    @State private var expanded = false

    var body: some View {
        if !failures.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(failures) { failure in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(failure.name)
                                .font(.system(.caption, design: .monospaced))
                            Text(failure.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            // Only shown when a mirror is involved: on a
                            // single-destination job the root is the same for
                            // every row and repeating it is noise.
                            if !isSingleDestination {
                                Text(failure.destination)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        Divider()
                    }
                    if totalFailures > failures.count {
                        Text("…and \(totalFailures - failures.count) more, listed in the log.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                }
                .textSelection(.enabled)
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)

                Button("Copy Details") { copyToPasteboard() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.top, 6)
            } label: {
                Text(expanded ? "Hide the files that failed" : "Show the files that failed")
                    .font(.callout)
            }
            .frame(maxWidth: 460)
        }
    }

    private var isSingleDestination: Bool {
        Set(failures.map(\.destination)).count <= 1
    }

    /// Plain text, so it pastes into an email, a note or an issue unchanged.
    private func copyToPasteboard() {
        var lines = ["\(totalFailures) file(s) failed to copy:"]
        for failure in failures {
            lines.append("  \(failure.name) → \(failure.destination)")
            lines.append("      \(failure.reason)")
        }
        if totalFailures > failures.count {
            lines.append("  …and \(totalFailures - failures.count) more (see the job log).")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
