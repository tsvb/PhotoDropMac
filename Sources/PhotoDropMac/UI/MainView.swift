import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(DriveWatcher.self) private var watcher
    @Environment(AppCoordinator.self) private var coordinator
    @State private var planner = IngestPlanner()
    @State private var copier = Copier()
    @State private var verifier = Verifier()
    @State private var presetStore = PresetStore()

    @AppStorage("photodrop.primaryDestination") private var primaryDest: String = ""
    @AppStorage("photodrop.archiveDestination") private var archiveDest: String = ""
    @AppStorage("photodrop.extraArchiveDestinations") private var extraArchives: String = ""
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
    /// Separate from `preflightMessage` because this one has no "Ingest Anyway".
    @State private var topologyRefusal: String?

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
                    onIngest: startIngest,
                    presetStore: presetStore
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
            // Summary suppressed for a completion → return to the idle preview
            // instead of lingering in the completed state (mirrors dismissing the
            // sheet). Expressed as the complement of the presentation gate so the
            // two can't drift: reset exactly when the summary won't be shown.
            if case .completed = newState,
               !newState.shouldPresentCompletionSummary(showSetting: showCompletionSheet) {
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
        // No "Ingest Anyway": with overlapping trees there is no version of
        // proceeding that copies anything.
        .alert(
            "These folders overlap",
            isPresented: Binding(
                get: { topologyRefusal != nil },
                set: { if !$0 { topologyRefusal = nil } }
            ),
            presenting: topologyRefusal
        ) { _ in
            Button("OK", role: .cancel) { topologyRefusal = nil }
        } message: { message in
            Text(message + "\n\nChoose a destination outside the card, and destinations that don’t contain one another.")
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
        SelectionSummary.of(yearGroups: planner.yearGroups, deselected: deselectedIDs).bundles
    }

    private func startIngest() {
        guard source != nil, !primaryDest.isEmpty else { return }
        let groups = selectedYearGroups()
        guard !groups.isEmpty else { return }
        let primaryURL = URL(fileURLWithPath: primaryDest, isDirectory: true)

        // Overlapping trees are refused, with no "Ingest Anyway": the job would
        // copy nothing, report success, and eject the card. Checked here so the
        // user hears it before pressing Ingest; `IngestEngine` enforces it again
        // for every other caller.
        if let refusal = PreflightCheck.topologyRefusal(
            source: source.map { URL(fileURLWithPath: $0.mountPoint, isDirectory: true) },
            primary: primaryURL,
            archives: archiveDestinations
        ) {
            topologyRefusal = refusal
            return
        }

        // Preflight on the *selected* bytes: warn (don't hard-block) if a
        // destination volume looks too full. The user can still proceed —
        // dedup may make it fit.
        let plannedBytes = groups.reduce(Int64(0)) { $0 + $1.totalBytes }
        if let warning = PreflightCheck.spaceWarning(
            plannedBytes: plannedBytes,
            primary: primaryURL,
            archives: archiveDestinations
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
            archiveDestinations: archiveDestinations,
            description: descriptionText,
            verify: verifyCopies,
            // Never eject on the strength of a partial view of the card. If the
            // scan couldn't open every folder, what it missed exists *only* on the
            // card, and ejecting is the step that puts it out of reach.
            ejectAfter: ejectAfterIngest && planner.scanWasComplete,
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

    // The full ordered list of archive (mirror) destinations: the primary
    // archive followed by any additional locations.
    private var archiveDestinations: [URL] {
        ArchiveDestinations.list(primary: primaryDest, archive: archiveDest, extra: extraArchives)
    }

    // Fulfils a one-click request from the menu bar: once the requested card
    // has been scanned and a destination is set, start the ingest through the
    // normal path so progress shows in this window.
    private func tryAutoIngest() {
        switch AutoIngestGate.decide(pending: autoIngestPending,
                                     isScanning: planner.isScanning,
                                     totalFiles: planner.totalFiles,
                                     hasDestination: !primaryDest.isEmpty,
                                     copierIsRunning: copier.isRunning) {
        case .idle, .wait:
            return
        case .abandon:
            // Disarm. This used to fall out of a `guard` with the flag still set
            // and only one retry trigger (the end of a scan), so one-clicking a
            // card with no recognized photos left the request armed — and the
            // *next* card inserted, hours later, was ingested with no user
            // action at all. Clearing the coordinator field also matters: it is
            // what makes a second click on the same card a change `onChange` can
            // see, so re-clicking after fixing the destination works.
            autoIngestPending = false
            coordinator.pendingOneClickCardID = nil
        case .start:
            autoIngestPending = false
            coordinator.pendingOneClickCardID = nil
            startIngest()
        }
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
                // The *selected* count: the contact sheet can deselect most of a
                // card, and a subtitle that keeps reporting everything found
                // contradicts the button next to it.
                let selected = SelectionSummary.of(yearGroups: planner.yearGroups, deselected: deselectedIDs)
                if selected.files < planner.totalFiles {
                    return "\(size) · \(selected.files.formatted()) of \(planner.totalFiles.formatted()) photos selected"
                }
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
                verifying: copier.isVerifyingCurrentJob,
                onCancel: { copier.cancel() }
            )
        case .cancelled(let result):
            ContentUnavailableView {
                Label("Ingest cancelled", systemImage: "xmark.octagon")
            } description: {
                Text(cancelledDescription)
            } actions: {
                // The receipt for what *did* land. A cancel deliberately leaves
                // those files in place, so the manifest and log are the only
                // record of which ones they were.
                JobArtifactButtons(result: result)
                Button("Reset") { copier.reset() }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let msg, let result):
            ContentUnavailableView {
                Label("Ingest failed", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            } description: {
                Text(failedDescription(msg))
            } actions: {
                JobArtifactButtons(result: result)
                Button("Reset") { copier.reset() }
                    .buttonStyle(.borderedProminent)
            }
        case .idle, .completed:
            idleContent
        }
    }

    private var cancelledDescription: String {
        var s = "Partial files from the current bundle were rolled back."
        if let landed = landedPhrase { s += " \(landed)" }
        return s
    }

    private func failedDescription(_ message: String) -> String {
        var s = message
        if let landed = landedPhrase { s += " \(landed) —" }
        s += " The failing file is still on the card."
        return s
    }

    /// What actually landed, worded to match what was actually checked. With
    /// verification on, `verifiedBundles` counts bundles re-read and hash-matched
    /// after the write, so "verified" is a claim the app can back. With it off
    /// nothing was read back, and the only honest word is "copied".
    private var landedPhrase: String? {
        let verified = copier.verifiedBundles
        if verified > 0 {
            return "The \(verified) already-verified bundle\(verified == 1 ? " is" : "s are") safe on disk."
        }
        let completed = copier.completedBundles
        if completed > 0 {
            return "The \(completed) completed bundle\(completed == 1 ? " is" : "s are") on disk (copy verification was off)."
        }
        return nil
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
        } else if planner.sourceUnreadable {
            // Distinct from "no photos found": that reads as a fact about the
            // card, and the user acts on it by reformatting or moving on.
            ContentUnavailableView(
                "Card could not be read",
                systemImage: "exclamationmark.triangle.fill",
                description: Text("This card is not readable — it may have been removed, or the volume may be damaged. Nothing was scanned.")
            )
        } else if planner.yearGroups.isEmpty {
            ContentUnavailableView(
                "No photos found",
                systemImage: "photo",
                description: Text("This card has no recognized photo files.")
            )
        } else {
            VStack(spacing: 0) {
                // A partial scan is stated where the file list is, not only in the
                // log: the count beside the Ingest button is what the user checks
                // their card against, and it was silently short.
                if planner.unreadableDirectories > 0 {
                    IncompleteScanBanner(count: planner.unreadableDirectories)
                }
                switch previewMode {
                case .tree:
                    PreviewTree(yearGroups: planner.yearGroups, deselected: deselectedIDs)
                case .grid:
                    ContactSheet(yearGroups: planner.yearGroups, deselectedIDs: $deselectedIDs, loader: loader)
                }
            }
        }
    }
}

/// Shown when the card walk couldn't open every folder. Says plainly that the
/// list below is incomplete and that the card will not be ejected, because the
/// combination of an incomplete list and an ejected card is how photos get lost.
private struct IncompleteScanBanner: View {
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) folder\(count == 1 ? "" : "s") on this card couldn’t be read")
                    .fontWeight(.semibold)
                Text("The list below may not be everything on the card. The card won’t be ejected after this ingest.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15))
        .accessibilityElement(children: .combine)
    }
}

/// Whether a pending one-click ingest request should start, keep waiting, or be
/// given up on.
///
/// Pulled out of `MainView.tryAutoIngest` so the decision can be tested: the
/// original was a `guard` chain that returned without clearing the request on
/// *any* failure, which armed an ingest that a later, unrelated card could fire.
/// The distinction that matters is between "not yet" (a scan is still running)
/// and "never" (the card holds nothing, no destination is set, a job is already
/// running) — a guard chain cannot express it, which is why it got this wrong.
enum AutoIngestGate {
    enum Decision: Equatable { case idle, wait, start, abandon }

    static func decide(pending: Bool,
                       isScanning: Bool,
                       totalFiles: Int,
                       hasDestination: Bool,
                       copierIsRunning: Bool) -> Decision {
        guard pending else { return .idle }
        if isScanning { return .wait }
        guard totalFiles > 0, hasDestination, !copierIsRunning else { return .abandon }
        return .start
    }
}
