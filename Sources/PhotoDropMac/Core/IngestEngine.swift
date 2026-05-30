import Foundation

// Progress snapshot. Cumulative MB/s (not delta-windowed) gives a meaningful
// number from tick one. A value type so it crosses the off-main engine /
// main-actor controller boundary freely.
struct CopyProgress: Sendable, Equatable, Hashable {
    let totalBundles: Int
    let completedBundles: Int
    let verifiedBundles: Int
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
    let manifestURL: URL?
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

/// Headless ingest engine: indexes each destination, builds collision-safe
/// plans, copies every bundle (tee-hash + optional verify + dedup + per-bundle
/// rollback) to the primary and every mirror, flushes each volume, optionally
/// ejects the card, and writes the verification manifest + log.
///
/// Nonisolated and single-task: callers run it off the main actor (the `Copier`
/// controller via a detached `Task`; the CLI directly) and supply progress/log
/// callbacks plus a cancellation check. Returns the `CopyResult`, or `nil` if it
/// was cancelled before completion (no manifest/log written in that case).
/// Notifications and the post-ingest hook are the caller's responsibility.
final class IngestEngine {
    private let bundles: [AssetBundle]
    private let description: String
    private let primaryRoot: URL
    private let archiveRoots: [URL]
    private let verify: Bool
    private let ejectAfter: Bool
    private let sourceMountPoint: String?
    private let sourceVolumeID: String
    private let template: NamingTemplate
    private let cardLabel: String
    private let cache: HashCache
    private let indexStoreURL: URL
    private let isCancelled: () -> Bool
    private let onProgress: (CopyProgress) -> Void
    private let onLog: (LogEntry) -> Void

    private let startedAt = Date()
    private var totalBytes: Int64 = 0
    private var bytesCopied: Int64 = 0
    private var totalBundles = 0
    private var completedBundles = 0
    private var verifiedBundles = 0
    private var filesCopied = 0
    private var filesSkipped = 0
    private var filesFailed = 0
    private var currentFile = ""
    private var manifestEntries: [ManifestEntry] = []
    private var logEntries: [LogEntry] = []
    private var lastProgressTick: Date

    init(bundles: [AssetBundle],
         description: String,
         primaryRoot: URL,
         archiveRoots: [URL],
         verify: Bool,
         ejectAfter: Bool,
         sourceMountPoint: String?,
         sourceVolumeID: String,
         template: NamingTemplate,
         cardLabel: String,
         cache: HashCache,
         indexStoreURL: URL,
         isCancelled: @escaping () -> Bool = { false },
         onProgress: @escaping (CopyProgress) -> Void = { _ in },
         onLog: @escaping (LogEntry) -> Void = { _ in }) {
        self.bundles = bundles
        self.description = description
        self.primaryRoot = primaryRoot
        self.archiveRoots = archiveRoots
        self.verify = verify
        self.ejectAfter = ejectAfter
        self.sourceMountPoint = sourceMountPoint
        self.sourceVolumeID = sourceVolumeID
        self.template = template
        self.cardLabel = cardLabel
        self.cache = cache
        self.indexStoreURL = indexStoreURL
        self.isCancelled = isCancelled
        self.onProgress = onProgress
        self.onLog = onLog
        self.lastProgressTick = startedAt
    }

    func run() async -> CopyResult? {
        totalBundles = bundles.count
        let perDestinationBytes = bundles.reduce(Int64(0)) { $0 + $1.totalSize }
        // Primary at index 0, then each archive mirror.
        let allRoots = [primaryRoot] + archiveRoots
        totalBytes = perDestinationBytes * Int64(allRoots.count)

        log(.info, "Starting ingest: \(bundles.count) bundles, \(totalBytes.formatted(.byteCount(style: .file)))\(allRoots.count > 1 ? " × \(allRoots.count) destinations" : "")")
        emitProgress(force: true)

        // Build a dedup index + collision-safe plans per destination. Collision
        // avoidance only needs the *specific* day-folders this job writes into, so
        // it scans those fresh, independent of the (cached) dedup index — a new
        // different-content file that maps onto an existing name gets a "_1"
        // variant instead of overwriting; planBatch's in-batch set handles
        // same-run collisions.
        log(.info, "Indexing destinations for duplicate detection…")
        var indexes: [DestinationIndex] = []
        var plansPerRoot: [[BundlePlan]] = []
        for root in allRoots {
            let index = DestinationIndex.build(at: root, storeURL: indexStoreURL)
            let targetDirs = Set(bundles.map {
                CopyPlan.destinationDirectory(for: $0, destinationRoot: root, description: description, template: template, cardLabel: cardLabel)
            })
            let existing = DestinationIndex.existingFilePaths(in: targetDirs)
            let plans = CopyPlan.planBatch(bundles: bundles, destinationRoot: root, description: description, template: template, cardLabel: cardLabel, existingPaths: existing)
            indexes.append(index)
            plansPerRoot.append(plans)
        }

        var haltReason: String?
        let bundleCount = plansPerRoot.first?.count ?? 0
        outer: for i in 0..<bundleCount {
            if isCancelled() { haltReason = "cancelled"; break }
            do {
                // Copy the bundle to every destination; only the primary (index 0)
                // records the manifest — the mirrors are byte-identical. Each
                // copyBundle rolls back its own destination on failure.
                for d in allRoots.indices {
                    try await copyBundle(plansPerRoot[d][i], index: indexes[d], recordManifest: d == 0, root: allRoots[d])
                }
                completedBundles += 1
                verifiedBundles += 1
                emitProgress(force: true)
            } catch is CancellationError {
                haltReason = "cancelled"
                break outer
            } catch let err as FileCopierError {
                switch err {
                case .verificationMismatch:
                    log(.error, err.description)
                    log(.error, "Halting job on verification mismatch.")
                    haltReason = "verification mismatch"
                    break outer
                default:
                    log(.error, err.description)
                    filesFailed += 1
                    completedBundles += 1
                    emitProgress(force: true)
                    continue
                }
            } catch {
                log(.error, "Bundle failed: \(error.localizedDescription)")
                filesFailed += 1
                completedBundles += 1
                emitProgress(force: true)
                continue
            }
        }

        let elapsed = Date().timeIntervalSince(startedAt)

        if haltReason == "cancelled" || isCancelled() {
            log(.info, "Ingest cancelled after \(String(format: "%.1fs", elapsed)).")
            return nil
        }

        // One F_FULLFSYNC per destination volume now that every file is fsync'd —
        // makes the whole job durable against power loss before we (optionally)
        // eject. Skipped when nothing new was written (an all-duplicate re-ingest).
        if filesCopied > 0 {
            log(.info, "Flushing destinations to disk…")
            var flushed = true
            for root in allRoots { flushed = FileCopier.fullSyncVolume(at: root) && flushed }
            if !flushed {
                log(.error, "Warning: could not force a device-cache flush; copies are written but may not survive an immediate power loss until the OS flushes them.")
            }
        }

        var didEject = false
        if haltReason == nil, ejectAfter, let mountPoint = sourceMountPoint {
            log(.info, "Ejecting card…")
            do {
                try await DriveEjector.eject(mountPoint: mountPoint)
                didEject = true
                log(.info, "Card ejected — safe to remove.")
            } catch {
                log(.error, "Eject failed: \(error.localizedDescription)")
            }
        }

        // Reported size = bytes that actually landed in the primary library (the
        // sum of the manifest entries), not the progress counter `bytesCopied`,
        // which counts every pass (≈N× under mirrors).
        let landedBytes = manifestEntries.reduce(Int64(0)) { $0 + $1.bytes }

        let manifest = Manifest(
            schema: Manifest.schemaID,
            app: Manifest.appName,
            createdAt: startedAt,
            source: sourceMountPoint.map { URL(fileURLWithPath: $0).lastPathComponent },
            primaryDestination: primaryRoot.path(percentEncoded: false),
            archiveDestination: archiveRoots.first?.path(percentEncoded: false),
            destinations: allRoots.map { $0.path(percentEncoded: false) },
            verified: verify,
            filesCopied: filesCopied,
            filesSkipped: filesSkipped,
            filesFailed: filesFailed,
            totalBytes: landedBytes,
            elapsedSeconds: elapsed,
            files: manifestEntries
        )
        let manifestURL = ManifestWriter.write(manifest, intoRoot: primaryRoot, stamp: startedAt)
        if manifestURL != nil {
            log(.info, "Verification manifest written to “\(ManifestWriter.folderName)”.")
        }

        let logURL = JobLogger.write(
            entries: logEntries,
            startedAt: startedAt,
            elapsedSeconds: elapsed,
            primaryDestination: primaryRoot,
            archiveDestinations: archiveRoots
        )

        // Persist the hash cache — misses populated during this run stay hot.
        try? await cache.save()

        log(.info, "Complete: \(filesCopied) copied, \(filesSkipped) skipped, \(filesFailed) failed.")

        return CopyResult(
            bundleCount: totalBundles,
            filesCopied: filesCopied,
            filesSkipped: filesSkipped,
            filesFailed: filesFailed,
            totalBytes: landedBytes,
            elapsedSeconds: elapsed,
            primaryDestination: primaryRoot,
            logURL: logURL,
            manifestURL: manifestURL,
            wasEjected: didEject,
            halted: haltReason != nil,
            haltReason: haltReason
        )
    }

    // MARK: - Per-bundle copy (all-or-nothing, with rollback)

    private func copyBundle(_ plan: BundlePlan, index: DestinationIndex, recordManifest: Bool, root: URL) async throws {
        var writtenFiles: [URL] = []
        // Counts + manifest entries are accumulated locally and committed to the
        // job totals only once every file in the bundle has landed (below), so a
        // bundle that fails partway and rolls back leaves no trace.
        var bundleManifest: [ManifestEntry] = []
        var copiedInBundle = 0
        var skippedInBundle = 0

        do {
            for file in plan.files {
                if isCancelled() { throw CancellationError() }

                currentFile = file.source.lastPathComponent
                emitProgress()

                // Dedup check — routes through HashCache so a re-run skips file
                // reads when (size, mtime) is unchanged on both sides.
                let existingDuplicate = await index.findDuplicate(
                    sourceSize: file.size,
                    sourceVolumeID: sourceVolumeID,
                    sourceURL: file.source,
                    using: cache
                )

                if let existingDuplicate {
                    log(.skipped, "\(file.source.lastPathComponent) — already present as \(existingDuplicate.lastPathComponent)")
                    skippedInBundle += 1
                    if recordManifest {
                        bundleManifest.append(ManifestEntry(
                            name: file.source.lastPathComponent,
                            path: relativePath(of: existingDuplicate, under: root),
                            bytes: file.size,
                            xxhash64: nil,
                            status: "skipped"
                        ))
                    }
                    bytesCopied += file.size   // count skip bytes so the bar fills smoothly
                    emitProgress()
                    continue
                }

                // Copy + tee-hash, inline on the engine's (off-main) thread.
                // copyAndHash creates the destination exclusively (O_EXCL) and
                // removes its own partial on failure, so we register the file for
                // bundle-level rollback only once it is fully written.
                let dest = file.destination
                let copyHash = try FileCopier.copyAndHash(
                    source: file.source, destination: dest, isCancelled: isCancelled
                ) { chunkBytes in
                    self.bytesCopied += chunkBytes
                    self.emitProgress()
                }
                writtenFiles.append(dest)

                if verify {
                    try FileCopier.verify(file: dest, expectedHash: copyHash)
                    log(.verified, "\(file.source.lastPathComponent) → \(dest.lastPathComponent)", signature: copyHash)
                } else {
                    log(.copied, "\(file.source.lastPathComponent) → \(dest.lastPathComponent)")
                }

                await cache.recordDestination(url: dest, hash: copyHash)
                // Stamp the digest into an xattr so the file carries its own
                // checksum (survives a library reorg / a lost manifest).
                // Best-effort — silently no-ops on volumes without xattr support.
                FileChecksumXattr.stamp(copyHash, on: dest)

                if recordManifest {
                    bundleManifest.append(ManifestEntry(
                        name: file.source.lastPathComponent,
                        path: relativePath(of: dest, under: root),
                        bytes: file.size,
                        xxhash64: String(format: "%016llx", copyHash),
                        status: verify ? "verified" : "copied"
                    ))
                }
                copiedInBundle += 1
            }
        } catch {
            // Roll back this bundle's written files; discard its local tallies.
            if !writtenFiles.isEmpty {
                log(.error, "Rolling back \(writtenFiles.count) file(s) from the failed bundle.")
                let fm = FileManager.default
                for url in writtenFiles.reversed() { try? fm.removeItem(at: url) }
            }
            throw error
        }

        // Bundle fully landed: commit its tallies and manifest entries now.
        filesCopied += copiedInBundle
        filesSkipped += skippedInBundle
        if recordManifest { manifestEntries.append(contentsOf: bundleManifest) }
    }

    // MARK: - Progress / log

    private func emitProgress(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastProgressTick) <= 0.1 { return }
        lastProgressTick = now
        onProgress(currentProgress())
    }

    private func currentProgress() -> CopyProgress {
        CopyProgress(
            totalBundles: totalBundles,
            completedBundles: completedBundles,
            verifiedBundles: verifiedBundles,
            totalBytes: totalBytes,
            bytesCopied: bytesCopied,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            currentFile: currentFile
        )
    }

    private func log(_ kind: LogEntry.Kind, _ message: String, signature: UInt64? = nil) {
        let entry = LogEntry(timestamp: Date(), kind: kind, line: message, signature: signature)
        logEntries.append(entry)
        onLog(entry)
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        // Compare path *components* rather than string prefixes: a directory URL
        // renders with a trailing slash via path(percentEncoded:), which would
        // defeat a naive hasPrefix and leave an absolute path in the manifest
        // (re-verify then can't find the file).
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        if urlComponents.count > rootComponents.count,
           Array(urlComponents.prefix(rootComponents.count)) == rootComponents {
            return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }
        return url.path(percentEncoded: false)
    }
}
