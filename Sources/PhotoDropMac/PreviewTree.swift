import SwiftUI

struct PreviewTree: View {
    let yearGroups: [YearGroup]

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
        let files = yearGroups.reduce(0) { $0 + $1.totalFiles }
        let bytes = yearGroups.reduce(0) { $0 + $1.totalBytes }
        return "\(files.formatted()) files · \(bytes.formatted(.byteCount(style: .file)))"
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.dayName)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                Text("\(folder.fileCount.formatted()) files · \(folder.totalBytes.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}
