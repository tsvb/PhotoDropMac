import Foundation
import Observation

/// UI state for the ingest flow. The copy work itself lives in the nonisolated
/// `IngestEngine` (Core); this enum is the controller's view state.
enum CopierState: Equatable {
    case idle
    case running(CopyProgress)
    case completed(CopyResult)
    case cancelled
    case failed(String)
}

extension CopierState {
    /// Whether the completion-summary sheet should be presented for this state,
    /// honouring the user's "Show completion summary" preference. A finish that
    /// had failures is always surfaced, so disabling the summary can never
    /// silently hide files that didn't land — important for a never-lossy tool.
    func shouldPresentCompletionSummary(showSetting: Bool) -> Bool {
        guard case .completed(let result) = self else { return false }
        return showSetting || result.filesFailed > 0
    }
}

/// Drives `IngestEngine` off the main actor and reflects its progress/log/result
/// into observable UI state. A thin wrapper — all the copy logic is in the
/// engine, which the CLI shares. Notifications and the post-ingest hook are
/// handled here (UI concerns), not in the engine.
@MainActor
@Observable
final class Copier {
    private(set) var state: CopierState = .idle
    private(set) var log: [LogEntry] = []
    // Bundles fully copied + verified so far — surfaced in the cancelled/failed
    // states to reassure the user what is safely on disk.
    private(set) var verifiedBundles: Int = 0

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    @ObservationIgnored private let cache: HashCache
    @ObservationIgnored private let indexStoreURL: URL
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelFlag = CancellationFlag()

    // Store URLs for the dedup cache and destination-index snapshot are
    // injectable so tests can point them at a temp directory; production uses
    // the real Application Support locations.
    init(cacheStoreURL: URL = HashCache.defaultURL, indexStoreURL: URL = DestinationIndex.defaultStoreURL) {
        self.cache = HashCache(storeURL: cacheStoreURL)
        self.indexStoreURL = indexStoreURL
    }

    func cancel() {
        task?.cancel()
        cancelFlag.cancel()
        if case .running = state { state = .cancelled }
    }

    func reset() {
        state = .idle
        log = []
        task = nil
    }

    func start(
        yearGroups: [YearGroup],
        primaryDestination: URL,
        archiveDestinations: [URL],
        description: String,
        verify: Bool,
        ejectAfter: Bool,
        sourceMountPoint: String?,
        sourceVolumeID: String,
        template: NamingTemplate,
        cardLabel: String
    ) {
        cancel()                          // abort any in-flight run (trips its flag)
        let flag = CancellationFlag()
        cancelFlag = flag
        log.removeAll()
        verifiedBundles = 0

        let allBundles = yearGroups.flatMap { $0.folders.flatMap { $0.bundles } }
        guard !allBundles.isEmpty else {
            state = .failed("No photos to copy.")
            return
        }

        state = .running(CopyProgress(totalBundles: allBundles.count, completedBundles: 0,
                                      verifiedBundles: 0, totalBytes: 0, bytesCopied: 0,
                                      elapsedSeconds: 0, currentFile: ""))

        let cache = self.cache
        let indexStoreURL = self.indexStoreURL
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { [weak self] () -> CopyResult? in
                let engine = IngestEngine(
                    bundles: allBundles, description: description, primaryRoot: primaryDestination,
                    archiveRoots: archiveDestinations, verify: verify, ejectAfter: ejectAfter,
                    sourceMountPoint: sourceMountPoint, sourceVolumeID: sourceVolumeID,
                    template: template, cardLabel: cardLabel, cache: cache, indexStoreURL: indexStoreURL,
                    isCancelled: { flag.isCancelled },
                    onProgress: { progress in Task { @MainActor [weak self] in self?.applyProgress(progress) } },
                    onLog: { entry in Task { @MainActor [weak self] in self?.appendLogEntry(entry) } }
                )
                return await engine.run()
            }.value

            guard let self, !flag.isCancelled else { return }   // cancelled or superseded
            if let result {
                if result.halted {
                    self.state = .failed("Halted: \(result.haltReason ?? "error"). See log.")
                    Notifier.notifyHalt(reason: result.haltReason ?? "error")
                } else {
                    self.state = .completed(result)
                    Notifier.notifyCompletion(result: result)
                    self.runPostIngestHookIfConfigured(result)
                }
            } else {
                self.state = .cancelled
            }
        }
    }

    private func applyProgress(_ progress: CopyProgress) {
        verifiedBundles = progress.verifiedBundles
        if case .running = state { state = .running(progress) }
    }

    private func appendLogEntry(_ entry: LogEntry) {
        log.append(entry)
        // Cap the in-memory log to keep the UI snappy; the on-disk log has all.
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // Runs the user's post-ingest hook (if configured) on a clean completion —
    // fire-and-forget so a slow hook can't delay the completion UI, and
    // best-effort so a missing/failing hook never affects the copy result.
    private func runPostIngestHookIfConfigured(_ result: CopyResult) {
        let script = (UserDefaults.standard.string(forKey: PostIngestHook.defaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        Task.detached(priority: .utility) {
            do {
                try await PostIngestHook.run(scriptPath: script, result: result)
            } catch let error as PostIngestHookError {
                await Notifier.notifyHookFailure(message: error.message)
            } catch {
                await Notifier.notifyHookFailure(message: error.localizedDescription)
            }
        }
    }
}
