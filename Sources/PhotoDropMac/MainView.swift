import SwiftUI

struct MainView: View {
    @Environment(DriveWatcher.self) private var watcher
    @State private var planner = IngestPlanner()
    @State private var copier = Copier()

    @AppStorage("photodrop.primaryDestination") private var primaryDest: String = ""
    @AppStorage("photodrop.archiveDestination") private var archiveDest: String = ""
    @AppStorage("photodrop.verifyCopies") private var verifyCopies: Bool = true
    @AppStorage("photodrop.ejectAfterIngest") private var ejectAfterIngest: Bool = false

    @State private var selectedSourceID: DetectedDrive.ID?
    @State private var descriptionText: String = ""
    @State private var showInspector: Bool = true

    private var source: DetectedDrive? {
        guard let id = selectedSourceID else { return nil }
        return watcher.drives.first { $0.id == id }
    }

    private var completionResult: CopyResult? {
        if case .completed(let result) = copier.state { return result }
        return nil
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selectedSourceID)
        } detail: {
            DetailPane(
                source: source,
                planner: planner,
                copier: copier
            )
            .navigationTitle(source?.label ?? "PhotoDrop")
            .navigationSubtitle(detailSubtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        watcher.rescan()
                        planner.setSource(source, description: descriptionText)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Rescan cards and preview")
                    .disabled(copier.isRunning)

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
                    description: $descriptionText,
                    canStart: canStartIngest,
                    onIngest: startIngest
                )
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
            .sheet(item: Binding<CopyResult?>(
                get: { completionResult },
                set: { newValue in
                    if newValue == nil {
                        copier.reset()
                    }
                }
            )) { result in
                CompletionSheet(result: result, onDismiss: { copier.reset() })
            }
        }
        .onAppear {
            if selectedSourceID == nil {
                selectedSourceID = watcher.drives.first?.id
            }
            planner.setSource(source, description: descriptionText)
        }
        .onChange(of: watcher.drives) { _, drives in
            if let id = selectedSourceID, !drives.contains(where: { $0.id == id }) {
                selectedSourceID = drives.first?.id
            } else if selectedSourceID == nil {
                selectedSourceID = drives.first?.id
            }
        }
        .onChange(of: selectedSourceID) { _, _ in
            planner.setSource(source, description: descriptionText)
        }
        .onChange(of: descriptionText) { _, new in
            planner.updateDescription(new)
        }
    }

    private var canStartIngest: Bool {
        source != nil
            && !planner.isScanning
            && planner.totalFiles > 0
            && !primaryDest.isEmpty
            && !copier.isRunning
    }

    private func startIngest() {
        guard let source else { return }
        guard !primaryDest.isEmpty else { return }
        let primaryURL = URL(fileURLWithPath: primaryDest, isDirectory: true)
        let archiveURL: URL? = archiveDest.isEmpty
            ? nil
            : URL(fileURLWithPath: archiveDest, isDirectory: true)
        copier.start(
            yearGroups: planner.yearGroups,
            primaryDestination: primaryURL,
            archiveDestination: archiveURL,
            description: descriptionText,
            verify: verifyCopies,
            ejectAfter: ejectAfterIngest,
            sourceMountPoint: source.mountPoint
        )
    }

    private var detailSubtitle: String {
        guard let source else { return "" }
        let size = source.totalBytes.formatted(.byteCount(style: .file))
        switch copier.state {
        case .running(let progress):
            return "\(size) · Ingesting \(Int(progress.percent * 100))%"
        case .completed:
            return size
        case .cancelled:
            return "\(size) · Cancelled"
        case .failed:
            return "\(size) · Failed"
        case .idle:
            if planner.isScanning {
                return "\(size) · Scanning…"
            } else if planner.totalFiles > 0 {
                return "\(size) · \(planner.totalFiles.formatted()) photos"
            } else {
                return size
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
            Spacer(minLength: 0)
            Button {
                let mountPoint = card.mountPoint
                Task { try? await DriveEjector.eject(mountPoint: mountPoint) }
            } label: {
                Image(systemName: "eject.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Eject \(card.label)")
        }
        .padding(.vertical, 2)
    }
}

struct DetailPane: View {
    let source: DetectedDrive?
    let planner: IngestPlanner
    let copier: Copier

    var body: some View {
        switch copier.state {
        case .running(let progress):
            ProgressPane(
                progress: progress,
                log: copier.log,
                onCancel: { copier.cancel() }
            )
        case .cancelled:
            ContentUnavailableView {
                Label("Ingest cancelled", systemImage: "xmark.octagon")
            } description: {
                Text("Partial files from the current bundle were rolled back.")
            } actions: {
                Button("Reset") { copier.reset() }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let msg):
            ContentUnavailableView {
                Label("Ingest failed", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(msg)
            } actions: {
                Button("Reset") { copier.reset() }
                    .buttonStyle(.borderedProminent)
            }
        case .idle, .completed:
            idleContent
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        if source == nil {
            ContentUnavailableView(
                "No card selected",
                systemImage: "sdcard",
                description: Text("Insert a memory card to begin.")
            )
        } else if planner.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Scanning card…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if planner.yearGroups.isEmpty {
            ContentUnavailableView(
                "No photos found",
                systemImage: "photo",
                description: Text("This card has no recognized photo files.")
            )
        } else {
            PreviewTree(yearGroups: planner.yearGroups)
        }
    }
}
