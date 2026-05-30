import Foundation
import Observation

// Progress snapshot for the UI. Cumulative MB/s (not delta-windowed)
// gives a meaningful number from tick one.
struct CopyProgress: Sendable, Equatable, Hashable {
    let totalBundles: Int
    let completedBundles: Int
    let totalBytes: Int64
    let bytesCopied: Int64
    let elapsedSeconds: Double
    let currentFile: String

    var percent: Double {
        totalBytes == 0 ? 0 : Double(bytesCopied) / Double(totalBytes)
    }
    var mibPerSecond: Double {
        elapsedSeconds < 0.05 ? 0 : Double(bytesCopied) / elapsedSeconds / (1024 * 1024)
    }
    var eta: TimeInterval? {
        guard bytesCopied > 0, elapsedSeconds > 0.5, bytesCopied < totalBytes else { return nil }
        let speed = Double(bytesCopied) / elapsedSeconds
        return Double(totalBytes - bytesCopied) / speed
    }
}

struct CopyResult: Sendable, Identifiable, Equatable, Hashable {
    let id = UUID()
    let bundleCount: Int
    let filesCopied: Int
    let filesSkipped: Int
    let filesFailed: Int
    let totalBytes: Int64
    let elapsedSeconds: Double
    let primaryDestination: URL
    let logURL: URL?
    let wasEjected: Bool
    let halted: Bool
    let haltReason: String?
}

struct LogEntry: Sendable, Hashable, Identifiable {
    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let line: String
    let signature: UInt64?   // xxHash of the verified file; nil for other kinds

    enum Kind: Sendable, Hashable {
        case info, copied, skipped, verified, error
    }
}

enum CopierState: Equatable {
    case idle
    case running(CopyProgress)
    case completed(CopyResult)
    case cancelled
    case failed(String)
}

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

    @ObservationIgnored private let cache = HashCache(storeURL: HashCache.defaultURL)
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date = Date()
    @ObservationIgnored private var totalBytes: Int64 = 0
    @ObservationIgnored private var bytesCopied: Int64 = 0
    @ObservationIgnored private var totalBundles: Int = 0
    @ObservationIgnored private var completedBundles: Int = 0
    @ObservationIgnored private var filesCopied: Int = 0
    @ObservationIgnored private var filesSkipped: Int = 0
    @ObservationIgnored private var filesFailed: Int = 0
    @ObservationIgnored private var currentFile: String = ""

    func cancel() {
        task?.cancel()
    }

    func reset() {
        state = .idle
        log = []
        task = nil
    }

    func start(
        yearGroups: [YearGroup],
        primaryDestination: URL,
        archiveDestination: URL?,
        description: String,
        verify: Bool,
        ejectAfter: Bool,
        sourceMountPoint: String?,
        sourceVolumeID: String,
        template: NamingTemplate,
        cardLabel: String
    ) {
        task?.cancel()
        log.removeAll()
        startedAt = Date()
        bytesCopied = 0
        completedBundles = 0
        verifiedBundles = 0
        filesCopied = 0
        filesSkipped = 0
        filesFailed = 0
        currentFile = ""

        let allBundles = yearGroups.flatMap { $0.folders.flatMap { $0.bundles } }
        guard !allBundles.isEmpty else {
            state = .failed("No photos to copy.")
            return
        }

        totalBundles = allBundles.count
        // The plans (and thus exact destination filenames) are built later in
        // run(), once the destination index is known — collision-safe naming
        // needs to see what's already on disk. Byte totals don't depend on
        // naming, so we size the progress bar up front straight from the bundles.
        let perDestinationBytes = allBundles.reduce(Int64(0)) { $0 + $1.totalSize }
        totalBytes = perDestinationBytes * (archiveDestination == nil ? 1 : 2)

        appendLog(.info, "Starting ingest: \(allBundles.count) bundles, \(totalBytes.formatted(.byteCount(style: .file)))\(archiveDestination == nil ? "" : " × 2 destinations")")
        state = .running(currentProgress())

        task = Task { [weak self] in
            guard let self else { return }
            await self.run(
                bundles: allBundles,
                description: description,
                primaryRoot: primaryDestination,
                archiveRoot: archiveDestination,
                verify: verify,
                ejectAfter: ejectAfter,
                sourceMountPoint: sourceMountPoint,
                sourceVolumeID: sourceVolumeID,
                template: template,
                cardLabel: cardLabel
            )
        }
    }

    private func run(
        bundles: [AssetBundle],
        description: String,
        primaryRoot: URL,
        archiveRoot: URL?,
        verify: Bool,
        ejectAfter: Bool,
        sourceMountPoint: String?,
        sourceVolumeID: String,
        template: NamingTemplate,
        cardLabel: String
    ) async {
        appendLog(.info, "Indexing destinations for duplicate detection…")
        let primaryIndex = await Task.detached(priority: .userInitiated) {
            DestinationIndex.build(at: primaryRoot)
        }.value
        let archiveIndex: DestinationIndex?
        if let archiveRoot {
            archiveIndex = await Task.detached(priority: .userInitiated) {
                DestinationIndex.build(at: archiveRoot)
            }.value
        } else {
            archiveIndex = nil
        }

        // Build collision-safe plans. Collision avoidance only needs to know
        // which files already sit in the *specific* day-folders this job writes
        // into — never the whole library — so we scan just those target dirs
        // fresh, independent of the (cached) dedup index above. Seeding
        // planBatch with them means a new, different-content file that would map
        // onto an existing name gets a "_1" variant instead of overwriting it;
        // planBatch's own in-batch set handles same-run collisions.
        let primaryPlans = await Task.detached(priority: .userInitiated) {
            let targetDirs = Set(bundles.map {
                CopyPlan.destinationDirectory(for: $0, destinationRoot: primaryRoot, description: description, template: template, cardLabel: cardLabel)
            })
            let existing = DestinationIndex.existingFilePaths(in: targetDirs)
            return CopyPlan.planBatch(bundles: bundles, destinationRoot: primaryRoot, description: description, template: template, cardLabel: cardLabel, existingPaths: existing)
        }.value
        let archivePlans: [BundlePlan]
        if let archiveRoot {
            archivePlans = await Task.detached(priority: .userInitiated) {
                let targetDirs = Set(bundles.map {
                    CopyPlan.destinationDirectory(for: $0, destinationRoot: archiveRoot, description: description, template: template, cardLabel: cardLabel)
                })
                let existing = DestinationIndex.existingFilePaths(in: targetDirs)
                return CopyPlan.planBatch(bundles: bundles, destinationRoot: archiveRoot, description: description, template: template, cardLabel: cardLabel, existingPaths: existing)
            }.value
        } else {
            archivePlans = []
        }

        var haltReason: String?

        outer: for i in 0..<primaryPlans.count {
            if Task.isCancelled { haltReason = "cancelled"; break }

            let primaryPlan = primaryPlans[i]
            do {
                try await copyBundle(primaryPlan, index: primaryIndex, verify: verify, sourceVolumeID: sourceVolumeID)

                if i < archivePlans.count, let archiveIndex {
                    try await copyBundle(archivePlans[i], index: archiveIndex, verify: verify, sourceVolumeID: sourceVolumeID)
                }

                completedBundles += 1
                verifiedBundles += 1
                state = .running(currentProgress())
            } catch is CancellationError {
                haltReason = "cancelled"
                break outer
            } catch let err as FileCopierError {
                switch err {
                case .verificationMismatch:
                    appendLog(.error, err.description)
                    appendLog(.error, "Halting job on verification mismatch.")
                    haltReason = "verification mismatch"
                    break outer
                default:
                    appendLog(.error, err.description)
                    filesFailed += 1
                    completedBundles += 1
                    state = .running(currentProgress())
                    continue
                }
            } catch {
                appendLog(.error, "Bundle failed: \(error.localizedDescription)")
                filesFailed += 1
                completedBundles += 1
                state = .running(currentProgress())
                continue
            }
        }

        let elapsed = Date().timeIntervalSince(startedAt)

        // Cancellation short-circuit
        if haltReason == "cancelled" || Task.isCancelled {
            appendLog(.info, "Ingest cancelled after \(String(format: "%.1fs", elapsed)).")
            state = .cancelled
            return
        }

        // Device-cache barrier: one F_FULLFSYNC per destination volume now that
        // every file has been fsync'd to the filesystem. This makes the whole
        // job durable against power loss before we (optionally) eject — far
        // cheaper than the per-file full barrier it replaces. Skipped when
        // nothing new was written (an all-duplicate re-ingest).
        if filesCopied > 0 {
            appendLog(.info, "Flushing destinations to disk…")
            let flushed = await Task.detached(priority: .userInitiated) { () -> Bool in
                var ok = FileCopier.fullSyncVolume(at: primaryRoot)
                if let archiveRoot { ok = FileCopier.fullSyncVolume(at: archiveRoot) && ok }
                return ok
            }.value
            if !flushed {
                appendLog(.error, "Warning: could not force a device-cache flush; copies are written but may not survive an immediate power loss until the OS flushes them.")
            }
        }

        // Optional eject
        var didEject = false
        if haltReason == nil, ejectAfter, let mountPoint = sourceMountPoint {
            appendLog(.info, "Ejecting card…")
            do {
                try await DriveEjector.eject(mountPoint: mountPoint)
                didEject = true
                appendLog(.info, "Card ejected — safe to remove.")
            } catch {
                appendLog(.error, "Eject failed: \(error.localizedDescription)")
            }
        }

        // Persist log file (best-effort, non-fatal if it fails)
        let capturedEntries = log
        let capturedStart = startedAt
        let logURL = await Task.detached(priority: .utility) {
            JobLogger.write(
                entries: capturedEntries,
                startedAt: capturedStart,
                elapsedSeconds: elapsed,
                primaryDestination: primaryRoot,
                archiveDestination: archiveRoot
            )
        }.value

        // Persist the hash cache — misses populated during this run stay
        // hot for next time. Fire-and-forget: a save failure isn't fatal.
        try? await cache.save()

        let result = CopyResult(
            bundleCount: totalBundles,
            filesCopied: filesCopied,
            filesSkipped: filesSkipped,
            filesFailed: filesFailed,
            totalBytes: bytesCopied,
            elapsedSeconds: elapsed,
            primaryDestination: primaryRoot,
            logURL: logURL,
            wasEjected: didEject,
            halted: haltReason != nil,
            haltReason: haltReason
        )

        appendLog(.info, "Complete: \(filesCopied) copied, \(filesSkipped) skipped, \(filesFailed) failed.")

        if let haltReason {
            state = .failed("Halted: \(haltReason). See log.")
        } else {
            state = .completed(result)
        }
    }

    // MARK: - Per-bundle copy (with rollback on failure)

    private func copyBundle(_ plan: BundlePlan, index: DestinationIndex, verify: Bool, sourceVolumeID: String) async throws {
        var writtenFiles: [URL] = []

        do {
            for file in plan.files {
                try Task.checkCancellation()

                currentFile = file.source.lastPathComponent
                state = .running(currentProgress())

                // Dedup check — routes through HashCache so a re-run of
                // the same card + destination skips file reads entirely
                // when (size, mtime) is unchanged on both sides.
                let existingDuplicate: URL? = await index.findDuplicate(
                    sourceSize: file.size,
                    sourceVolumeID: sourceVolumeID,
                    sourceURL: file.source,
                    using: cache
                )

                if let existingDuplicate {
                    appendLog(.skipped, "\(file.source.lastPathComponent) — already present as \(existingDuplicate.lastPathComponent)")
                    filesSkipped += 1
                    // Count skip bytes toward progress so the bar fills smoothly.
                    bytesCopied += file.size
                    state = .running(currentProgress())
                    continue
                }

                // Copy + tee-hash. Register the destination for rollback
                // *before* the first byte is written: if the copy throws or is
                // cancelled mid-file, the partial file must be cleaned up too,
                // not just this bundle's already-completed siblings.
                let source = file.source
                let dest = file.destination
                writtenFiles.append(file.destination)
                let copyHash = try await Task.detached(priority: .userInitiated) { [weak self] in
                    var buffered: Int64 = 0
                    var lastFlush = Date()
                    let hash = try FileCopier.copyAndHash(source: source, destination: dest) { chunkBytes in
                        buffered += chunkBytes
                        let now = Date()
                        if now.timeIntervalSince(lastFlush) > 0.1 {
                            let delta = buffered
                            buffered = 0
                            lastFlush = now
                            Task { @MainActor [weak self] in
                                self?.addBytesCopied(delta)
                            }
                        }
                    }
                    if buffered > 0 {
                        let delta = buffered
                        Task { @MainActor [weak self] in
                            self?.addBytesCopied(delta)
                        }
                    }
                    return hash
                }.value

                // Verification
                if verify {
                    try await Task.detached(priority: .userInitiated) {
                        try FileCopier.verify(file: dest, expectedHash: copyHash)
                    }.value
                    appendLog(.verified, "\(file.source.lastPathComponent) → \(file.destination.lastPathComponent)", signature: copyHash)
                } else {
                    appendLog(.copied, "\(file.source.lastPathComponent) → \(file.destination.lastPathComponent)")
                }

                // Populate the destination cache entry so the next dedup
                // run doesn't re-hash this file.
                await cache.recordDestination(url: file.destination, hash: copyHash)

                filesCopied += 1
            }
        } catch {
            // Rollback the partial bundle
            if !writtenFiles.isEmpty {
                appendLog(.error, "Rolling back \(writtenFiles.count) partial file(s) from this bundle.")
                await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    for url in writtenFiles.reversed() {
                        try? fm.removeItem(at: url)
                    }
                }.value
            }
            throw error
        }
    }

    // MARK: - Progress / log helpers

    private func addBytesCopied(_ delta: Int64) {
        bytesCopied += delta
        state = .running(currentProgress())
    }

    private func currentProgress() -> CopyProgress {
        CopyProgress(
            totalBundles: totalBundles,
            completedBundles: completedBundles,
            totalBytes: totalBytes,
            bytesCopied: bytesCopied,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            currentFile: currentFile
        )
    }

    private func appendLog(_ kind: LogEntry.Kind, _ message: String, signature: UInt64? = nil) {
        log.append(LogEntry(timestamp: Date(), kind: kind, line: message, signature: signature))
        // Cap in-memory log to keep the UI snappy. The on-disk log file
        // written at end-of-job contains the same entries.
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
    }
}
