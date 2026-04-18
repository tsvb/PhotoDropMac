import SwiftUI

struct MainView: View {
    @Environment(DriveWatcher.self) private var watcher

    @State private var selectedSourceID: DetectedDrive.ID?
    @State private var primaryDestination: String = "/Users/tim/Photos/RAW"
    @State private var archiveDestination: String = ""
    @State private var descriptionText: String = ""
    @State private var verify: Bool = true
    @State private var ejectWhenDone: Bool = false
    @State private var showInspector: Bool = true

    private var source: DetectedDrive? {
        guard let id = selectedSourceID else { return nil }
        return watcher.drives.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selectedSourceID)
        } detail: {
            DetailPane(source: source)
                .navigationTitle(source?.label ?? "PhotoDrop")
                .navigationSubtitle(source.map { $0.totalBytes.formatted(.byteCount(style: .file)) } ?? "")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            watcher.rescan()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Rescan cards")

                        Button {
                            showInspector.toggle()
                        } label: {
                            Label("Toggle Inspector", systemImage: "sidebar.right")
                        }
                        .help("Toggle inspector")
                    }
                }
                .inspector(isPresented: $showInspector) {
                    InspectorPane(
                        primary: $primaryDestination,
                        archive: $archiveDestination,
                        description: $descriptionText,
                        verify: $verify,
                        ejectWhenDone: $ejectWhenDone,
                        canStart: source != nil
                    )
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        }
        .onAppear {
            if selectedSourceID == nil {
                selectedSourceID = watcher.drives.first?.id
            }
        }
        .onChange(of: watcher.drives) { _, drives in
            if let id = selectedSourceID, !drives.contains(where: { $0.id == id }) {
                selectedSourceID = drives.first?.id
            } else if selectedSourceID == nil {
                selectedSourceID = drives.first?.id
            }
        }
    }
}

struct Sidebar: View {
    @Environment(DriveWatcher.self) private var watcher
    @Binding var selection: DetectedDrive.ID?

    var body: some View {
        Group {
            if watcher.drives.isEmpty {
                ContentUnavailableView(
                    "No Cards",
                    systemImage: "sdcard",
                    description: Text("Insert a memory card to begin.")
                )
            } else {
                List(watcher.drives, selection: $selection) { card in
                    SidebarRow(card: card)
                        .tag(card.id)
                }
                .listStyle(.sidebar)
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
    }
}

struct SidebarRow: View {
    let card: DetectedDrive

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sdcard.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(card.totalBytes.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DetailPane: View {
    let source: DetectedDrive?

    var body: some View {
        if source != nil {
            PreviewTree(nodes: Sample.previewTree)
        } else {
            ContentUnavailableView(
                "No card selected",
                systemImage: "sdcard",
                description: Text("Insert a memory card to begin.")
            )
        }
    }
}
