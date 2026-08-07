import Foundation
import Observation

/// UI state for the ingest flow. The copy work itself lives in the nonisolated
/// `IngestEngine` (Core); this enum is the controller's view state.
enum CopierState: Equatable {
    case idle
    case running(CopyProgress)
    case completed(CopyResult)
    /// Carries the result once the engine finishes unwinding — `nil` in the
    /// window between the user hitting Cancel and the engine writing its
    /// manifest for the bundles that already landed.
    case cancelled(CopyResult?)
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
    // states to reassure the user what is safely on disk. Zero when the job ran
    // with verification off; `completedBundles` is the honest count in that case,
    // and the two are worded differently because they promise different things.
    private(set) var verifiedBundles: Int = 0
    private(set) var completedBundles: Int = 0

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    @ObservationIgnored private let cache: HashCache
    @ObservationIgnored private let indexStoreURL: URL
    @ObservationIgnored private let logDirectory: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let postsNotifications: Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelFlag = CancellationFlag()

    /// Everything this controller touches *outside* the destination folders is
    /// injectable, so a test run is indistinguishable from no run at all.
    ///
    /// Each default below is a real user-facing side effect that the suite was
    /// firing on every integration test: the dedup cache and index snapshot in
    /// Application Support; `~/Library/Logs/PhotoDrop`, which is the user's audit
    /// trail for what happened to their photos (measured: +18 files per run);
    /// `UNUserNotificationCenter`, which prompts for permission the first time;
    /// and `UserDefaults.standard`, which is read for a post-ingest script the
    /// controller would then **execute** — latent only because the developer
    /// happens to have no hook configured.
    init(cacheStoreURL: URL = HashCache.defaultURL,
         indexStoreURL: URL = DestinationIndex.defaultStoreURL,
         logDirectory: URL? = nil,
         defaults: UserDefaults = .standard,
         postsNotifications: Bool = true) {
        self.cache = HashCache(storeURL: cacheStoreURL)
        self.indexStoreURL = indexStoreURL
        self.logDirectory = logDirectory
        self.defaults = defaults
        self.postsNotifications = postsNotifications
    }

    /// A copier that writes nothing outside `directory` and raises no banners.
    /// Tests should use this rather than assembling the parameters by hand, so a
    /// side effect added later has one place to be contained.
    static func hermetic(in directory: URL) -> Copier {
        Copier(cacheStoreURL: directory.appendingPathComponent("hash-cache.json"),
               indexStoreURL: directory.appendingPathComponent("dest-index.json"),
               logDirectory: directory.appendingPathComponent("Logs", isDirectory: true),
               defaults: UserDefaults(suiteName: "photodrop.tests.\(UUID().uuidString)") ?? .standard,
               postsNotifications: false)
    }

    func cancel() {
        task?.cancel()
        cancelFlag.cancel()
        if case .running = state { state = .cancelled(nil) }
    }

    func reset() {
        // Retire the current generation, not just the visible state.
        //
        // `reset()` used to leave `cancelFlag` intact while dropping `task`, so
        // the in-flight run's completion guard (`self.cancelFlag === flag`) still
        // matched: the engine finished its tail — rollback, fsync, manifest, log —
        // and then set `state = .cancelled(result)`, making the app jump from an
        // idle screen back to the "Ingest cancelled" panel seconds after the user
        // dismissed it, with no user action in between.
        cancelFlag.cancel()
        cancelFlag = CancellationFlag()
        state = .idle
        log = []
        task = nil
        verifiedBundles = 0
        completedBundles = 0
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
        completedBundles = 0

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
        let logDirectory = self.logDirectory
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { [weak self] () -> CopyResult in
                let engine = IngestEngine(
                    bundles: allBundles, description: description, primaryRoot: primaryDestination,
                    archiveRoots: archiveDestinations, verify: verify, ejectAfter: ejectAfter,
                    sourceMountPoint: sourceMountPoint, sourceVolumeID: sourceVolumeID,
                    template: template, cardLabel: cardLabel, cache: cache, indexStoreURL: indexStoreURL,
                    logDirectory: logDirectory,
                    isCancelled: { flag.isCancelled },
                    // Both hops carry the same generation check as the result
                    // path below. Without it, a superseded run's tail lines —
                    // "Ingest cancelled after 12.3s…", "Complete: 40 copied" —
                    // arrived *after* `log.removeAll()` and appended into the next
                    // job's visible log, and `applyProgress` overwrote the new
                    // job's counters. The log is the surface this app asks the
                    // user to trust about what happened to their photos; it may
                    // not carry another job's lines.
                    onProgress: { progress in Task { @MainActor [weak self] in self?.applyProgress(progress, from: flag) } },
                    onLog: { entry in Task { @MainActor [weak self] in self?.appendLogEntry(entry, from: flag) } }
                )
                return await engine.run()
            }.value

            // Drop the result only if a *newer* run has taken over — comparing
            // the captured flag against the current one, not `flag.isCancelled`.
            // A user-initiated cancel trips this run's own flag, and its result
            // now carries the manifest and log for the bundles that did land;
            // discarding it here would throw away the very receipt the engine
            // stayed alive to write.
            guard let self, self.cancelFlag === flag else { return }
            if result.cancelled {
                self.state = .cancelled(result)
            } else if result.halted {
                self.state = .failed("Halted: \(result.haltReason ?? "error"). See log.")
                if self.postsNotifications { Notifier.notifyHalt(reason: result.haltReason ?? "error") }
            } else {
                self.state = .completed(result)
                if self.postsNotifications { Notifier.notifyCompletion(result: result) }
                self.runPostIngestHookIfConfigured(result)
            }
        }
    }

    private func applyProgress(_ progress: CopyProgress, from flag: CancellationFlag) {
        guard cancelFlag === flag else { return }
        verifiedBundles = progress.verifiedBundles
        completedBundles = progress.completedBundles
        if case .running = state { state = .running(progress) }
    }

    private func appendLogEntry(_ entry: LogEntry, from flag: CancellationFlag) {
        guard cancelFlag === flag else { return }
        log.append(entry)
        // Cap the in-memory log to keep the UI snappy; the on-disk log has all.
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // Runs the user's post-ingest hook (if configured) on a clean completion —
    // fire-and-forget so a slow hook can't delay the completion UI, and
    // best-effort so a missing/failing hook never affects the copy result.
    private func runPostIngestHookIfConfigured(_ result: CopyResult) {
        let script = (defaults.string(forKey: PostIngestHook.defaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        let postsNotifications = self.postsNotifications
        Task.detached(priority: .utility) {
            do {
                try await PostIngestHook.run(scriptPath: script, result: result)
            } catch let error as PostIngestHookError {
                if postsNotifications { await Notifier.notifyHookFailure(message: error.message) }
            } catch {
                if postsNotifications { await Notifier.notifyHookFailure(message: error.localizedDescription) }
            }
        }
    }
}
