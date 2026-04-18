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

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

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
        sourceMountPoint: String?
    ) {
        task?.cancel()
        log.removeAll()
        startedAt = Date()
        bytesCopied = 0
        completedBundles = 0
        filesCopied = 0
        filesSkipped = 0
        filesFailed = 0
        currentFile = ""

        let allBundles = yearGroups.flatMap { $0.folders.flatMap { $0.bundles } }
        guard !allBundles.isEmpty else {
            state = .failed("No photos to copy.")
            return
        }

        let primaryPlans = allBundles.map { CopyPlan.plan(bundle: $0, destinationRoot: primaryDestination, description: description) }
        let archivePlans: [BundlePlan] = archiveDestination.map { root in
            allBundles.map { CopyPlan.plan(bundle: $0, destinationRoot: root, description: description) }
        } ?? []

        totalBundles = allBundles.count
        totalBytes = primaryPlans.reduce(0) { $0 + $1.totalBytes }
            + archivePlans.reduce(0) { $0 + $1.totalBytes }

        appendLog(.info, "Starting ingest: \(allBundles.count) bundles, \(totalBytes.formatted(.byteCount(style: .file)))\(archiveDestination == nil ? "" : " × 2 destinations")")
        state = .running(currentProgress())

        task = Task { [weak self] in
            guard let self else { return }
            await self.run(
                primaryPlans: primaryPlans,
                archivePlans: archivePlans,
                primaryRoot: primaryDestination,
                archiveRoot: archiveDestination,
                verify: verify,
                ejectAfter: ejectAfter,
                sourceMountPoint: sourceMountPoint
            )
        }
    }

    private func run(
        primaryPlans: [BundlePlan],
        archivePlans: [BundlePlan],
        primaryRoot: URL,
        archiveRoot: URL?,
        verify: Bool,
        ejectAfter: Bool,
        sourceMountPoint: String?
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

        var haltReason: String?

        outer: for i in 0..<primaryPlans.count {
            if Task.isCancelled { haltReason = "cancelled"; break }

            let primaryPlan = primaryPlans[i]
            do {
                try await copyBundle(primaryPlan, index: primaryIndex, verify: verify)

                if i < archivePlans.count, let archiveIndex {
                    try await copyBundle(archivePlans[i], index: archiveIndex, verify: verify)
                }

                completedBundles += 1
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

    private func copyBundle(_ plan: BundlePlan, index: DestinationIndex, verify: Bool) async throws {
        var writtenFiles: [URL] = []

        do {
            for file in plan.files {
                try Task.checkCancellation()

                currentFile = file.source.lastPathComponent
                state = .running(currentProgress())

                // Dedup check — hashes source lazily only on size collision.
                let existingDuplicate: URL? = try await Task.detached(priority: .userInitiated) {
                    try index.findDuplicate(sourceSize: file.size) {
                        try XxHash64.hash(fileAt: file.source)
                    }
                }.value

                if let existingDuplicate {
                    appendLog(.skipped, "\(file.source.lastPathComponent) — already present as \(existingDuplicate.lastPathComponent)")
                    filesSkipped += 1
                    // Count skip bytes toward progress so the bar fills smoothly.
                    bytesCopied += file.size
                    state = .running(currentProgress())
                    continue
                }

                // Copy + tee-hash
                let source = file.source
                let dest = file.destination
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

                writtenFiles.append(file.destination)

                // Verification
                if verify {
                    try await Task.detached(priority: .userInitiated) {
                        try FileCopier.verify(file: dest, expectedHash: copyHash)
                    }.value
                    appendLog(.verified, "\(file.source.lastPathComponent) → \(file.destination.lastPathComponent)  [\(String(format: "%016llx", copyHash))]")
                } else {
                    appendLog(.copied, "\(file.source.lastPathComponent) → \(file.destination.lastPathComponent)")
                }

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

    private func appendLog(_ kind: LogEntry.Kind, _ message: String) {
        log.append(LogEntry(timestamp: Date(), kind: kind, line: message))
        // Cap in-memory log to keep the UI snappy. The on-disk log file
        // written at end-of-job contains the same entries.
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
    }
}
