import SwiftUI

struct ProgressPane: View {
    let progress: CopyProgress
    let log: [LogEntry]
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progressCard
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)
            Divider()
            LogView(entries: log)
        }
    }

    private var progressCard: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Ingesting… \(Int(progress.percent * 100))%")
                        .font(.headline)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel", role: .destructive, action: onCancel)
                        .controlSize(.small)
                }

                ProgressView(value: progress.percent)
                    .progressViewStyle(.linear)

                HStack(spacing: 10) {
                    Text("Bundle \(min(progress.completedBundles + 1, progress.totalBundles)) of \(progress.totalBundles)")
                    Text("·").foregroundStyle(.tertiary)
                    Text(throughput)
                    Text("·").foregroundStyle(.tertiary)
                    Text(etaText)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                if !progress.currentFile.isEmpty {
                    Text(progress.currentFile)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // Seal-grid trust badge — fills cell-by-cell as the job verifies.
            VStack(spacing: 4) {
                SealGrid(progress: progress.percent)
                    .frame(width: 52, height: 52)
                Text("VERIFIED")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var throughput: String {
        "\(progress.mibPerSecond.formatted(.number.precision(.fractionLength(1)))) MB/s"
    }

    private var etaText: String {
        guard let eta = progress.eta else { return "—" }
        let total = Int(eta)
        let mins = total / 60
        let secs = total % 60
        return mins > 0 ? "\(mins)m \(secs)s left" : "\(secs)s left"
    }
}

struct LogView: View {
    let entries: [LogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: iconName(for: entry.kind))
                                .foregroundStyle(color(for: entry.kind))
                                .frame(width: 14, alignment: .leading)
                            Text(entry.line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: entry.kind))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let signature = entry.signature {
                                VerifiedSignature(hash: signature)
                            }
                        }
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .onChange(of: entries.count) { _, _ in
                if let lastID = entries.last?.id {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func iconName(for kind: LogEntry.Kind) -> String {
        switch kind {
        case .info:     return "info.circle"
        case .copied:   return "arrow.down.doc"
        case .skipped:  return "arrow.right.doc"
        case .verified: return "checkmark.seal.fill"
        case .error:    return "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .error:    return .red
        case .verified: return .green
        case .skipped:  return .secondary
        case .copied:   return .primary
        case .info:     return .secondary
        }
    }
}

#Preview("Activity log") {
    LogView(entries: [
        LogEntry(timestamp: .now, kind: .info,
                 line: "Starting ingest: 482 bundles, 24.6 GB", signature: nil),
        LogEntry(timestamp: .now, kind: .copied,
                 line: "DSCF1839.RAF → 20260417_120002_DSCF1839.RAF", signature: nil),
        LogEntry(timestamp: .now, kind: .verified,
                 line: "DSCF1840.RAF → 20260417_120004_DSCF1840.RAF", signature: 0xA3F7_8C12_45D9_7FA3),
        LogEntry(timestamp: .now, kind: .verified,
                 line: "DSCF1841.RAF → 20260417_120006_DSCF1841.RAF", signature: 0x2C91_3344_5566_77F9),
        LogEntry(timestamp: .now, kind: .skipped,
                 line: "DSCF1842.RAF — already present as 20260417_120008_DSCF1842.RAF", signature: nil),
        LogEntry(timestamp: .now, kind: .error,
                 line: "Verify mismatch on DSCF1843.RAF — destination copy deleted", signature: nil),
    ])
    .frame(width: 580, height: 220)
}

#Preview("Progress pane") {
    ProgressPane(
        progress: CopyProgress(
            totalBundles: 482, completedBundles: 311,
            totalBytes: 26_400_000_000, bytesCopied: 17_000_000_000,
            elapsedSeconds: 442, currentFile: "108_FUJI/DSCF1840.RAF"
        ),
        log: [
            LogEntry(timestamp: .now, kind: .copied, line: "DSCF1838.RAF → 20260417_120000_DSCF1838.RAF", signature: nil),
            LogEntry(timestamp: .now, kind: .verified, line: "DSCF1839.RAF → 20260417_120002_DSCF1839.RAF", signature: 0xA3F7_8C12_45D9_7FA3),
            LogEntry(timestamp: .now, kind: .skipped, line: "DSCF1840.RAF — already present as 20260417_120004_DSCF1840.RAF", signature: nil),
        ],
        onCancel: {}
    )
    .frame(width: 760, height: 460)
}
