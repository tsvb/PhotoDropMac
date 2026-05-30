import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(DriveWatcher.self) private var watcher
    @Environment(AppCoordinator.self) private var coordinator
    @State private var planner = IngestPlanner()
    @State private var copier = Copier()
    @State private var verifier = Verifier()

    @AppStorage("photodrop.primaryDestination") private var primaryDest: String = ""
    @AppStorage("photodrop.archiveDestination") private var archiveDest: String = ""
    @AppStorage("photodrop.verifyCopies") private var verifyCopies: Bool = true
    @AppStorage("photodrop.ejectAfterIngest") private var ejectAfterIngest: Bool = false
    @AppStorage("photodrop.template.folder") private var templateFolder = NamingTemplate.default.folder
    @AppStorage("photodrop.template.filename") private var templateFilename = NamingTemplate.default.filename
    @AppStorage("photodrop.showCompletionSheet") private var showCompletionSheet: Bool = true

    @State private var selectedSourceID: DetectedDrive.ID?
    @State private var descriptionText: String = ""
    @State private var showInspector: Bool = true
    @State private var autoIngestPending = false
    @State private var showVerifySheet = false
    @State private var previewMode: PreviewMode = .tree
    @State private var deselectedIDs: Set<AssetBundle.ID> = []
    @State private var thumbnailLoader = ThumbnailLoader()
    @State private var preflightMessage: String?

    private var source: DetectedDrive? {
        guard let id = selectedSourceID else { return nil }
        return watcher.drives.first { $0.id == id }
    }

    private var completionResult: CopyResult? {
        if case .completed(let result) = copier.state { return result }
        return nil
    }

    private var template: NamingTemplate {
        NamingTemplate(folder: templateFolder, filename: templateFilename)
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selectedSourceID)
        } detail: {
            DetailPane(
                source: source,
                planner: planner,
                copier: copier,
                previewMode: previewMode,
                deselectedIDs: $deselectedIDs,
                loader: thumbnailLoader
            )
            .navigationTitle(source?.label ?? "PhotoDrop")
            .navigationSubtitle(detailSubtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("Preview", selection: $previewMode) {
                        Image(systemName: "list.bullet").tag(PreviewMode.tree)
                        Image(systemName: "square.grid.2x2").tag(PreviewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .help("Tree or grid preview")

                    Button {
                        chooseVerifyTarget()
                    } label: {
                        Label("Verify Library", systemImage: "checkmark.shield")
                    }
                    .help("Re-verify a library folder against its manifest")
                    .disabled(copier.isRunning || verifier.isRunning)

                    Button {
                        watcher.rescan()
                        planner.setSource(source, description: descriptionText, template: template)
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
                get: { copier.state.shouldPresentCompletionSummary(showSetting: showCompletionSheet) ? completionResult : nil },
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
            planner.setSource(source, description: descriptionText, template: template)
        }
        .onChange(of: watcher.drives) { _, drives in
            if let id = selectedSourceID, !drives.contains(where: { $0.id == id }) {
                selectedSourceID = drives.first?.id
            } else if selectedSourceID == nil {
                selectedSourceID = drives.first?.id
            }
        }
        .onChange(of: selectedSourceID) { _, _ in
            deselectedIDs = []   // a different card → start with everything selected
            planner.setSource(source, description: descriptionText, template: template)
        }
        .onChange(of: descriptionText) { _, new in
            planner.updateDescription(new)
        }
        .onChange(of: templateFolder) { _, _ in planner.updateTemplate(template) }
        .onChange(of: templateFilename) { _, _ in planner.updateTemplate(template) }
        .onChange(of: coordinator.pendingOneClickCardID) { _, id in
            guard let id else { return }
            selectedSourceID = id
            autoIngestPending = true
            tryAutoIngest()
        }
        .onChange(of: planner.isScanning) { _, _ in
            tryAutoIngest()
        }
        .onChange(of: copier.state) { _, newState in
            // Summary suppressed for a clean finish → return to the idle preview
            // instead of lingering in the completed state (mirrors dismissing the
            // sheet). Finishes with failures keep their summary, so this only
            // resets when nothing failed.
            if case .completed(let result) = newState, !showCompletionSheet, result.filesFailed == 0 {
                copier.reset()
            }
        }
        .sheet(isPresented: $showVerifySheet) {
            VerifySheet(verifier: verifier) {
                showVerifySheet = false
                verifier.reset()
            }
        }
        .alert(
            "Not enough space",
            isPresented: Binding(
                get: { preflightMessage != nil },
                set: { if !$0 { preflightMessage = nil } }
            ),
            presenting: preflightMessage
        ) { _ in
            Button("Ingest Anyway") {
                preflightMessage = nil
                launchIngest(selectedYearGroups())
            }
            Button("Cancel", role: .cancel) { preflightMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var canStartIngest: Bool {
        source != nil
            && !planner.isScanning
            && planner.totalFiles > 0
            && !primaryDest.isEmpty
            && !copier.isRunning
            && selectedBundleCount > 0
    }

    private var selectedBundleCount: Int {
        planner.yearGroups
            .flatMap { $0.folders.flatMap(\.bundles) }
            .lazy.filter { !deselectedIDs.contains($0.id) }
            .count
    }

    private func startIngest() {
        guard source != nil, !primaryDest.isEmpty else { return }
        let groups = selectedYearGroups()
        guard !groups.isEmpty else { return }
        let primaryURL = URL(fileURLWithPath: primaryDest, isDirectory: true)
        // Preflight on the *selected* bytes: warn (don't hard-block) if a
        // destination volume looks too full. The user can still proceed —
        // dedup may make it fit.
        let plannedBytes = groups.reduce(Int64(0)) { $0 + $1.totalBytes }
        if let warning = PreflightCheck.spaceWarning(
            plannedBytes: plannedBytes,
            primary: primaryURL,
            archive: archiveURL
        ) {
            preflightMessage = warning
            return
        }
        launchIngest(groups)
    }

    private func launchIngest(_ groups: [YearGroup]) {
        guard let source, !primaryDest.isEmpty else { return }
        copier.start(
            yearGroups: groups,
            primaryDestination: URL(fileURLWithPath: primaryDest, isDirectory: true),
            archiveDestination: archiveURL,
            description: descriptionText,
            verify: verifyCopies,
            ejectAfter: ejectAfterIngest,
            sourceMountPoint: source.mountPoint,
            sourceVolumeID: source.id,
            template: template,
            cardLabel: source.label
        )
    }

    // Filter the planned groups down to the bundles still selected in the
    // contact sheet, dropping any now-empty folders/years.
    private func selectedYearGroups() -> [YearGroup] {
        planner.yearGroups.compactMap { yearGroup in
            let folders = yearGroup.folders.compactMap { folder -> DestinationFolder? in
                let bundles = folder.bundles.filter { !deselectedIDs.contains($0.id) }
                guard !bundles.isEmpty else { return nil }
                return DestinationFolder(
                    id: folder.id, year: folder.year, dayDate: folder.dayDate,
                    dayName: folder.dayName, bundles: bundles
                )
            }
            guard !folders.isEmpty else { return nil }
            return YearGroup(id: yearGroup.id, year: yearGroup.year, folders: folders)
        }
    }

    private var archiveURL: URL? {
        archiveDest.isEmpty ? nil : URL(fileURLWithPath: archiveDest, isDirectory: true)
    }

    // Fulfils a one-click request from the menu bar: once the requested card
    // has been scanned and a destination is set, start the ingest through the
    // normal path so progress shows in this window.
    private func tryAutoIngest() {
        guard autoIngestPending,
              !planner.isScanning,
              planner.totalFiles > 0,
              !primaryDest.isEmpty,
              !copier.isRunning
        else { return }
        autoIngestPending = false
        coordinator.pendingOneClickCardID = nil
        startIngest()
    }

    // Re-verify an existing library against its manifest. Accepts a library
    // folder (we find the manifests inside it) or a manifest .json directly.
    private func chooseVerifyTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a library folder, or a manifest .json, to re-verify."
        panel.prompt = "Verify"
        if !primaryDest.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: primaryDest, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            verifier.start(target: url)
            showVerifySheet = true
        }
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
    @AppStorage("photodrop.verificationStyle") private var theme = VerificationStyle.steady

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sdcard.fill")
                .font(.system(size: 18))
                .foregroundStyle(theme.resolvedAccent)
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
    let previewMode: PreviewMode
    @Binding var deselectedIDs: Set<AssetBundle.ID>
    let loader: ThumbnailLoader

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
                Text(cancelledDescription)
            } actions: {
                Button("Reset") { copier.reset() }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let msg):
            ContentUnavailableView {
                Label("Ingest failed", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            } description: {
                Text(failedDescription(msg))
            } actions: {
                Button("Reset") { copier.reset() }
                    .buttonStyle(.borderedProminent)
            }
        case .idle, .completed:
            idleContent
        }
    }

    private var cancelledDescription: String {
        let n = copier.verifiedBundles
        var s = "Partial files from the current bundle were rolled back."
        if n > 0 {
            s += " The \(n) already-verified bundle\(n == 1 ? " is" : "s are") safe on disk."
        }
        return s
    }

    private func failedDescription(_ message: String) -> String {
        let n = copier.verifiedBundles
        var s = message
        if n > 0 {
            s += " The \(n) already-verified bundle\(n == 1 ? " is" : "s are") safe on disk —"
            s += " the failing file is still on the card."
        } else {
            s += " The failing file is still on the card."
        }
        return s
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
            switch previewMode {
            case .tree:
                PreviewTree(yearGroups: planner.yearGroups)
            case .grid:
                ContactSheet(yearGroups: planner.yearGroups, deselectedIDs: $deselectedIDs, loader: loader)
            }
        }
    }
}
