import SwiftUI

enum PreviewMode: String, CaseIterable, Identifiable {
    case tree, grid
    var id: String { rawValue }
}

/// The culling surface: a thumbnail grid grouped by day with per-bundle,
/// per-day, and global selection. `deselectedIDs` is the negative space —
/// empty means everything is selected — so a fresh scan defaults to all-in
/// without having to enumerate ids.
struct ContactSheet: View {
    let yearGroups: [YearGroup]
    @Binding var deselectedIDs: Set<AssetBundle.ID>
    let loader: ThumbnailLoader

    @AppStorage("photodrop.verificationStyle") private var theme = VerificationStyle.steady

    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 168), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                summaryBar
                ForEach(yearGroups) { yearGroup in
                    ForEach(yearGroup.folders) { folder in
                        Section {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(folder.bundles) { bundle in
                                    ThumbnailCell(
                                        bundle: bundle,
                                        loader: loader,
                                        accent: theme.resolvedAccent,
                                        isSelected: isSelected(bundle.id),
                                        onToggle: { toggle(bundle.id) }
                                    )
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 6)
                        } header: {
                            dayHeader(folder)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var summaryBar: some View {
        let all = allBundles
        let selected = all.filter { isSelected($0.id) }
        let bytes = selected.reduce(Int64(0)) { $0 + $1.totalSize }
        return HStack(spacing: 8) {
            Text("\(selected.count) of \(all.count) selected")
                .font(.headline).monospacedDigit()
            Text("·").foregroundStyle(.tertiary)
            Text(bytes.formatted(.byteCount(style: .file)))
                .foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button("Select All") { deselectedIDs.removeAll() }
                .disabled(deselectedIDs.isEmpty)
            Button("Select None") { deselectedIDs = Set(all.map(\.id)) }
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func dayHeader(_ folder: DestinationFolder) -> some View {
        let ids = folder.bundles.map(\.id)
        let selectedInDay = ids.filter { isSelected($0) }.count
        return HStack(spacing: 8) {
            Text(folder.dayName).font(.subheadline.weight(.semibold))
            Text("\(selectedInDay)/\(folder.bundles.count)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button("All") { ids.forEach { deselectedIDs.remove($0) } }
                .buttonStyle(.borderless).controlSize(.small)
            Button("None") { deselectedIDs.formUnion(ids) }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var allBundles: [AssetBundle] {
        yearGroups.flatMap { $0.folders.flatMap(\.bundles) }
    }

    private func isSelected(_ id: AssetBundle.ID) -> Bool { !deselectedIDs.contains(id) }

    private func toggle(_ id: AssetBundle.ID) {
        if deselectedIDs.contains(id) { deselectedIDs.remove(id) } else { deselectedIDs.insert(id) }
    }
}

struct ThumbnailCell: View {
    let bundle: AssetBundle
    let loader: ThumbnailLoader
    let accent: Color
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var image: Image?

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(height: 104)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isSelected ? accent : Color.clear, lineWidth: 2.5)
                    }
                    .opacity(isSelected ? 1 : 0.4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? accent : Color.white.opacity(0.9))
                    .background(Circle().fill(.black.opacity(0.28)).padding(1))
                    .padding(5)
            }
            HStack(spacing: 4) {
                Text(bundle.primary.url.lastPathComponent)
                    .font(.caption2).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(bundle.primary.url.pathExtension.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .help(bundle.primary.url.lastPathComponent)
        .task(id: bundle.id) {
            if image == nil { image = await loader.image(for: bundle.primary.url) }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            image.resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(.quaternary)
                .overlay { ProgressView().controlSize(.small) }
        }
    }
}
