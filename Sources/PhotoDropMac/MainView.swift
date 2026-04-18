import SwiftUI

struct MainView: View {
    @State private var selectedSourceID: DetectedDrive.ID? = Sample.cards.first?.id
    @State private var primaryDestination: String = "/Users/tim/Photos/RAW"
    @State private var archiveDestination: String = ""
    @State private var descriptionText: String = ""
    @State private var verify: Bool = true
    @State private var ejectWhenDone: Bool = false
    @State private var showInspector: Bool = true

    private var source: DetectedDrive? {
        guard let id = selectedSourceID else { return nil }
        return Sample.cards.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selectedSourceID)
        } detail: {
            DetailPane(source: source)
                .navigationTitle(source?.label ?? "PhotoDrop")
                .navigationSubtitle(source.map(subtitle(for:)) ?? "")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            // TODO: refresh detected drives
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh cards")

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
    }

    private func subtitle(for drive: DetectedDrive) -> String {
        "\(drive.photoCount.formatted()) photos · \(drive.totalBytes.formatted(.byteCount(style: .file)))"
    }
}

struct Sidebar: View {
    @Binding var selection: DetectedDrive.ID?

    var body: some View {
        List(Sample.cards, selection: $selection) { card in
            SidebarRow(card: card)
                .tag(card.id)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        .overlay {
            if Sample.cards.isEmpty {
                ContentUnavailableView(
                    "No Cards",
                    systemImage: "sdcard",
                    description: Text("Insert a memory card to begin.")
                )
            }
        }
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
                Text("\(card.photoCount.formatted()) photos · \(card.totalBytes.formatted(.byteCount(style: .file)))")
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
                description: Text("Select a card from the sidebar to begin.")
            )
        }
    }
}
