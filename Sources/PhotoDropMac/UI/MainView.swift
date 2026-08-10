import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(DriveWatcher.self) private var watcher
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(Copier.self) private var copier
    @State private var planner = IngestPlanner()
    @State private var verifier = Verifier()
    @State private var presetStore = PresetStore()

    @AppStorage("photodrop.primaryDestination") private var primaryDest: String = ""
    @AppStorage("photodrop.archiveDestination") private var archiveDest: String = ""
    @AppStorage("photodrop.extraArchiveDestinations") private var extraArchives: String = ""
    @AppStorage("photodrop.verifyCopies") private var verifyCopies: Bool = true
    @AppStorage("photodrop.ejectAfterIngest") private var ejectAfterIngest: Bool = false
    @AppStorage("photodrop.template.folder") private var templateFolder = NamingTemplate.default.folder
    @AppStorage("photodrop.template.filename") private var templateFilename = NamingTemplate.default.filename
    @AppStorage("photodrop.template.yearFolder") private var templateYearFolder = NamingTemplate.default.yearFolder
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
        NamingTemplate(folder: templateFolder, filename: templateFilename, yearFolder: templateYearFolder)
    }

    /// Extracted from `body`.
    ///
    /// `body` measured **3.4 s** to type-check with the toolbar inline — under
    /// the compiler's hard limit locally, and exactly the shape that tips over
    /// it on a slower toolchain: `ApertureMark` did, on CI, with a build that
    /// was green on this machine. A view whose compilability depends on the host
    /// is not compilable.
    /// The detail column, lifted out of `body`.
    ///
    /// `body` is the largest expression in the app and the one the type checker
    /// charges most for; on CI's older toolchain that is the difference between
    /// a build and a failure (see `ApertureMark.draw`).
    private var detailColumn: some View {
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
        .toolbar { mainToolbar }
        .inspector(isPresented: $showInspector) {
            InspectorPane(
                description: $descriptionText,
                canStart: canStartIngest,
                onIngest: startIngest,
                presetStore: presetStore
            )
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .sheet(item: completionSheetBinding) { result in
            CompletionSheet(result: result, onDismiss: { copier.reset() })
        }
    }

    /// Also extracted from `body` — an inline `Binding(get:set:)` with a
    /// ternary inside a `.sheet(item:)` is another expression the type checker
    /// charges a lot for.
    private var completionSheetBinding: Binding<CopyResult?> {
        Binding<CopyResult?>(
            get: {
                guard copier.state.shouldPresentCompletionSummary(showSetting: showCompletionSheet)
                else { return nil }
                return completionResult
            },
            set: { newValue in
                if newValue == nil { copier.reset() }
            }
        )
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Preview", selection: $previewMode) {
                    Image(systemName: "list.bullet")
                        .accessibilityLabel("Tree preview")
                        .tag(PreviewMode.tree)
                    Image(systemName: "square.grid.2x2")
                        .accessibilityLabel("Grid preview")
                        .tag(PreviewMode.grid)
                }
                .pickerStyle(.segmented)
                // `.help` is the tooltip (NSAccessibilityHelp) — a different
                // attribute from the label VoiceOver announces. An
                // image-only control needs both.
                .help("Tree or grid preview")
                .accessibilityLabel("Preview mode")

                Button {
                    chooseVerifyTarget()
                } label: {
                    Label("Verify Library", systemImage: "checkmark.shield")
                }
                .help("Re-verify a library folder against its manifest")
                .accessibilityLabel("Verify library")
                .disabled(copier.isRunning || verifier.isRunning)

                Button {
                    watcher.rescan()
                    planner.setSource(source, description: descriptionText, template: template)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Rescan cards and preview")
                .accessibilityLabel("Refresh")
                .disabled(copier.isRunning)

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle inspector")
                .accessibilityLabel("Toggle inspector")
            }
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selectedSourceID)
        } detail: {
            detailColumn
        }
        .onAppear {
            selectedSourceID = DriveSelection.reconcile(current: selectedSourceID,
                                                        drives: watcher.drives.map(\.id))
            planner.setSource(source, description: descriptionText, template: template)
        }
        .onChange(of: watcher.drives) { _, drives in
            selectedSourceID = DriveSelection.reconcile(current: selectedSourceID,
                                                        drives: drives.map(\.id))
        }
        .modifier(PlanningHandlers(
            selectedSourceID: selectedSourceID,
            descriptionText: descriptionText,
            templateFolder: templateFolder,
            templateFilename: templateFilename,
            templateYearFolder: templateYearFolder,
            pendingOneClickCardID: coordinator.pendingOneClickCardID,
            isScanning: planner.isScanning,
            onSourceChanged: {
                deselectedIDs = []   // a different card → start with everything selected
                planner.setSource(source, description: descriptionText, template: template)
            },
            onDescriptionChanged: { planner.updateDescription($0) },
            onTemplateChanged: { planner.updateTemplate(template) },
            onOneClickRequested: { id in
                selectedSourceID = id
                autoIngestPending = true
                tryAutoIngest()
            },
            onScanStateChanged: { tryAutoIngest() }))
        // Menu commands. A `Commands` builder is scene-scoped and can't reach
        // this view's state, so it posts tickets on the coordinator and the
        // window performs them — see `PhotoDropCommands`. Grouped in one
        // modifier: four more `.onChange`s inline pushed this chain past what
        // the type checker will do in reasonable time.
        .modifier(MenuCommandHandlers(
            coordinator: coordinator,
            onRefresh: {
                guard !copier.isRunning else { return }
                watcher.rescan()
                planner.setSource(source, description: descriptionText, template: template)
            },
            onVerifyLibrary: {
                guard !copier.isRunning, !verifier.isRunning else { return }
                chooseVerifyTarget()
            },
            onToggleInspector: { showInspector.toggle() },
            onCancel: {
                guard copier.isRunning else { return }
                copier.cancel()
            }))
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
        .modifier(SheetsAndAlerts(
            showVerifySheet: $showVerifySheet,
            verifier: verifier,
            preflightMessage: $preflightMessage,
            topologyRefusal: $topologyRefusal,
            onIngestAnyway: { launchIngest(selectedYearGroups()) }))
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
        // Flush any debounced replan first: pressing Ingest immediately after
        // typing a description must copy into the folder the user just named,
        // not the one from before the last keystroke.
        planner.replanNow()
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
    @State private var ejectError: String?

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
                let label = card.label
                Task {
                    do {
                        try await DriveEjector.eject(mountPoint: mountPoint)
                    } catch {
                        // Reported, not swallowed: this is the one irreversible
                        // action in the app, and a failed eject that says nothing
                        // leaves the user pulling a mounted card.
                        ejectError = EjectOutcome.failureMessage(
                            card: label, error: error.localizedDescription)
                    }
                }
            } label: {
                Image(systemName: "eject.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Eject \(card.label)")
            .accessibilityLabel("Eject \(card.label)")
        }
        .padding(.vertical, 2)
        .alert("Eject failed", isPresented: Binding(
            get: { ejectError != nil }, set: { if !$0 { ejectError = nil } }
        )) {
            Button("OK", role: .cancel) { ejectError = nil }
        } message: { Text(ejectError ?? "") }
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

/// The verify sheet and the two ingest alerts.
///
/// Extracted from `MainView.body` for the same reason as `mainToolbar` and
/// `ApertureMark.draw`: `body` measured **3.4 s** to type-check as one
/// expression — under the compiler's hard ceiling on this machine and over it on
/// another, which is exactly how `ApertureMark` built green here and failed CI.
/// A view whose compilability depends on the host is not compilable.
private struct SheetsAndAlerts: ViewModifier {
    @Binding var showVerifySheet: Bool
    let verifier: Verifier
    @Binding var preflightMessage: String?
    @Binding var topologyRefusal: String?
    let onIngestAnyway: () -> Void

    func body(content: Content) -> some View {
        content
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
            onIngestAnyway()
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
}

/// The plan-affecting `onChange` handlers, grouped out of `MainView.body`.
///
/// Same reason as `MenuCommandHandlers` and `SheetsAndAlerts`: a long chain of
/// closures on one expression is what the type checker charges for, and CI's
/// older toolchain charges several times what this one does.
private struct PlanningHandlers: ViewModifier {
    let selectedSourceID: DetectedDrive.ID?
    let descriptionText: String
    let templateFolder: String
    let templateFilename: String
    let templateYearFolder: Bool
    let pendingOneClickCardID: DetectedDrive.ID?
    let isScanning: Bool

    let onSourceChanged: () -> Void
    let onDescriptionChanged: (String) -> Void
    let onTemplateChanged: () -> Void
    let onOneClickRequested: (DetectedDrive.ID) -> Void
    let onScanStateChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selectedSourceID) { _, _ in onSourceChanged() }
            .onChange(of: descriptionText) { _, new in onDescriptionChanged(new) }
            .onChange(of: templateFolder) { _, _ in onTemplateChanged() }
            .onChange(of: templateFilename) { _, _ in onTemplateChanged() }
            .onChange(of: templateYearFolder) { _, _ in onTemplateChanged() }
            .onChange(of: pendingOneClickCardID) { _, id in
                guard let id else { return }
                onOneClickRequested(id)
            }
            .onChange(of: isScanning) { _, _ in onScanStateChanged() }
    }
}

/// Delivers `AppCoordinator`'s menu tickets to the window.
private struct MenuCommandHandlers: ViewModifier {
    let coordinator: AppCoordinator
    let onRefresh: () -> Void
    let onVerifyLibrary: () -> Void
    let onToggleInspector: () -> Void
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: coordinator.refreshTicket) { _, _ in onRefresh() }
            .onChange(of: coordinator.verifyTicket) { _, _ in onVerifyLibrary() }
            .onChange(of: coordinator.inspectorTicket) { _, _ in onToggleInspector() }
            .onChange(of: coordinator.cancelTicket) { _, _ in onCancel() }
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
