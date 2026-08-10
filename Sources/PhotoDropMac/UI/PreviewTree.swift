import SwiftUI

struct PreviewTree: View {
    let yearGroups: [YearGroup]
    /// Bundles the user deselected in the contact sheet. The tree still lists
    /// every discovered file — the plan is the plan — but the header must count
    /// what will actually be copied, or it contradicts the Ingest button beside
    /// it.
    let deselected: Set<AssetBundle.ID>

    var body: some View {
        List {
            Section {
                ForEach(yearGroups) { year in
                    YearRow(group: year, defaultExpanded: true)
                }
            } header: {
                HStack {
                    Text("Preview").font(.headline)
                    Spacer()
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
    }

    private var summary: String {
        let counts = SelectionSummary.of(yearGroups: yearGroups, deselected: deselected)
        let base = "\(counts.files.formatted()) files · \(counts.bytes.formatted(.byteCount(style: .file)))"
        guard !deselected.isEmpty else { return base }
        let total = yearGroups.reduce(0) { $0 + $1.totalFiles }
        return base + " · \(total - counts.files) deselected"
    }
}

struct YearRow: View {
    let group: YearGroup
    @State private var isExpanded: Bool

    init(group: YearGroup, defaultExpanded: Bool = true) {
        self.group = group
        self._isExpanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.folders) { folder in
                FolderRow(folder: folder)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(group.year))
                        .fontWeight(.medium)
                    Text("\(group.totalFiles.formatted()) files · \(group.totalBytes.formatted(.byteCount(style: .file)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct FolderRow: View {
    let folder: DestinationFolder
    @AppStorage("photodrop.verificationStyle") private var theme = VerificationStyle.steady

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(theme.resolvedAccent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.dayName)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.resolvedAccent)
                Text("\(folder.fileCount.formatted()) files · \(folder.totalBytes.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}
