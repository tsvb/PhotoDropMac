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
        case .verified: return "checkmark.seal"
        case .error:    return "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .error:    return .red
        case .verified: return .green
        case .skipped:  return .orange
        case .copied:   return .primary
        case .info:     return .secondary
        }
    }
}
