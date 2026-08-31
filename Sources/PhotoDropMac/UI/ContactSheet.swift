import SwiftUI
import AppKit

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

    /// The cell the keyboard is on.
    ///
    /// The grid was a `LazyVGrid` of tap-gesture views: reachable by VoiceOver
    /// (the cells carry button traits and an accessibility action) but inert to
    /// plain keyboard, so culling 2,000 frames meant 2,000 mouse clicks. Arrow
    /// keys move, space toggles — the two gestures every culling tool in this
    /// category uses.
    @FocusState private var focusedID: AssetBundle.ID?

    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 168), spacing: 10)]

    /// Move the focus by `offset` positions through `orderedBundles`, clamped at
    /// both ends. Clamped rather than wrapped: wrapping from the last frame of a
    /// shoot back to the first is disorienting when you are working through a
    /// day in order.
    private func moveFocus(by offset: Int) {
        let bundles = allBundles
        guard !bundles.isEmpty else { return }
        guard let current = focusedID,
              let index = bundles.firstIndex(where: { $0.id == current }) else {
            focusedID = bundles.first?.id
            return
        }
        let next = min(max(index + offset, 0), bundles.count - 1)
        focusedID = bundles[next].id
    }

    /// How many cells sit on a row, for up/down movement.
    ///
    /// The grid is `.adaptive`, so the real count depends on the rendered width,
    /// which a `View` cannot ask for without a `GeometryReader` around the whole
    /// scroll view. This is a deliberate approximation: up/down moves by a
    /// typical row, and a user who lands one cell off corrects with one press.
    /// The alternative — threading a geometry read through the grid — costs more
    /// in layout churn than the imprecision costs in keystrokes.
    private let approximateColumnsPerRow = 6

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
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
                                            isFocused: focusedID == bundle.id,
                                            onToggle: { toggle(bundle.id) }
                                        )
                                        .focusable()
                                        .focused($focusedID, equals: bundle.id)
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
        // Arrow keys move, space toggles. `.onMoveCommand` receives the arrows
        // only while something inside is focused, which is why the cells are
        // `.focusable()`; the first Tab into the grid lands on the first cell.
        .onMoveCommand { direction in
            switch direction {
            case .left:  moveFocus(by: -1)
            case .right: moveFocus(by: 1)
            case .up:    moveFocus(by: -approximateColumnsPerRow)
            case .down:  moveFocus(by: approximateColumnsPerRow)
            @unknown default: break
            }
        }
        .onKeyPress(.space) {
            guard let focusedID else { return .ignored }
            toggle(focusedID)
            return .handled
        }
        // Return does what a double-click would: reveal the original on the card,
        // which is the only way to look at a frame larger than 104pt. A real
        // loupe is a bigger piece of work; this at least stops the grid being a
        // dead end when the user cannot tell whether a shot is sharp.
        .onKeyPress(.return) {
            guard let focusedID,
                  let bundle = allBundles.first(where: { $0.id == focusedID })
            else { return .ignored }
            NSWorkspace.shared.activateFileViewerSelecting([bundle.primary.url])
            return .handled
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
            Text("↑↓←→ move · space toggles · ⏎ reveals")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("The grid is keyboard-operable")
        }
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

    /// Every bundle in display order — which is both what the summary bar counts
    /// and the order the arrow keys walk.
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
    var isFocused: Bool = false
    let onToggle: () -> Void

    @State private var outcome: ThumbnailLoader.Outcome?

    var body: some View {
        VStack(spacing: 3) {
            frame
            caption
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .help(bundle.primary.url.lastPathComponent)
        // A visible focus ring, so keyboard position is legible. `.focusable`
        // alone draws nothing on a custom view.
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(-3)
            }
        }
        // VoiceOver: present each cell as a selectable button so the culling
        // grid is operable without sighted tapping. The selection state is
        // conveyed as the value, and "activate" toggles it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bundle.primary.url.lastPathComponent)
        .accessibilityValue(isSelected ? "Selected" : "Deselected")
        .accessibilityHint("Toggles whether this photo is included in the ingest")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onToggle() }
        .task(id: bundle.id) {
            if outcome == nil { outcome = await loader.outcome(for: bundle.primary.url) }
        }
    }

    /// Split out of `body`, like the mark views: this cell is instantiated once
    /// per photo on the card, and it was the last body in the target the type
    /// checker spent real time on. CI's older toolchain charges far more for the
    /// same expression than the local one does.
    private var frame: some View {
        ZStack(alignment: .topTrailing) {
            thumbnail
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .grayscale(isSelected ? 0 : 1)      // culled → desaturated…
                .opacity(isSelected ? 1 : 0.5)      // …and dimmed
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? accent : Color.primary.opacity(0.12),
                                      lineWidth: isSelected ? 2.5 : 1)
                }

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(isSelected ? accent : Color.white.opacity(0.85))
                .background(Circle().fill(.black.opacity(0.35)).padding(1))
                .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                .padding(5)
        }
    }

    private var caption: some View {
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

    @ViewBuilder
    private var thumbnail: some View {
        switch outcome {
        case .image(let image):
            image.resizable().aspectRatio(contentMode: .fill)
        case .undecodable:
            // A file ImageIO can't preview. Saying so beats a spinner that never
            // stops — and the decode is not retried on every reappearance.
            Rectangle().fill(.quaternary)
                .overlay {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
        case nil:
            Rectangle().fill(.quaternary)
                .overlay { ProgressView().controlSize(.small) }
        }
    }
}
