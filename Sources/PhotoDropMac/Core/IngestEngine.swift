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
    /// Total (bundle × destination) copy failures. With mirrors configured one
    /// bundle can fail at more than one destination, so this can exceed
    /// `bundleCount`; `failuresByDestination` breaks it down.
    let filesFailed: Int
    /// Failures per destination root path, primary included. A non-empty entry
    /// for a mirror with `primaryFailures == 0` is the "one mirror was offline,
    /// your library is fine" case, which must not be reported as a failed job.
    let failuresByDestination: [String: Int]
    let totalBytes: Int64
    let elapsedSeconds: Double
    let primaryDestination: URL
    let logURL: URL?
    let manifestURL: URL?
    let wasEjected: Bool
    let halted: Bool
    let haltReason: String?
    /// The user cancelled before every bundle was processed. The result is still
    /// a full record of what landed — including the manifest and log — rather
    /// than the absence of one.
    let cancelled: Bool

    /// Failures at the primary destination: what determines whether the
    /// *library* is incomplete, as opposed to one of its mirrors.
    var primaryFailures: Int {
        failuresByDestination[primaryDestination.path(percentEncoded: false)] ?? 0
    }

    /// Destinations other than the primary that had at least one failure.
    var failedMirrors: [String] {
        failuresByDestination
            .filter { $0.key != primaryDestination.path(percentEncoded: false) && $0.value > 0 }
            .keys.sorted()
    }
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
/// callbacks plus a cancellation check. Always returns a `CopyResult` — a
/// cancelled run reports `cancelled == true` and still carries its manifest and
/// log, because the bundles it already copied are on disk and need a record.
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
    /// Where the job log is written. Injected so a test run never adds to the
    /// user's real audit trail in ~/Library/Logs/PhotoDrop — see
    /// `JobLogger.defaultDirectory`.
    private let logDirectory: URL?
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
         logDirectory: URL? = nil,
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
        self.logDirectory = logDirectory
        self.isCancelled = isCancelled
        self.onProgress = onProgress
        self.onLog = onLog
        self.lastProgressTick = startedAt
    }

    func run() async -> CopyResult {
        totalBundles = bundles.count
        let perDestinationBytes = bundles.reduce(Int64(0)) { $0 + $1.totalSize }
        // Primary at index 0, then each archive mirror. Deduped by filesystem
        // identity: writing one folder twice makes pass 2 collide with pass 1's
        // own file, and `O_EXCL` correctly refuses — reporting every bundle
        // failed for an ingest that in fact succeeded.
        let allRoots = ArchiveDestinations.dedupedRoots([primaryRoot] + archiveRoots)
        if allRoots.count < 1 + archiveRoots.count {
            log(.info, "Ignoring \(1 + archiveRoots.count - allRoots.count) duplicate destination(s) — "
                     + "the same folder was listed more than once.")
        }
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
        for root in allRoots {
            indexes.append(DestinationIndex.build(at: root, storeURL: indexStoreURL))
        }

        // Plan **once**, then rebase the same relative paths onto every mirror.
        //
        // Planning per root let the `_1` disambiguator be chosen independently at
        // each destination, so the same photo could land as `…_IMG_0001_1.JPG` in
        // the primary and `…_IMG_0001.JPG` in the mirror. Only the primary's path
        // is recorded in the manifest, so `heal` would then look for the primary's
        // name under the mirror root, not find it, and report the file
        // unrecoverable with a perfect copy sitting right there.
        //
        // To keep one name valid everywhere, collision avoidance considers the
        // day-folders of *every* destination: a name is only free if it is free at
        // all of them.
        var existingRelative = Set<String>()
        for root in allRoots {
            let targetDirs = Set(bundles.map {
                CopyPlan.destinationDirectory(for: $0, destinationRoot: root, description: description, template: template, cardLabel: cardLabel)
            })
            for absolute in DestinationIndex.existingFilePaths(in: targetDirs) {
                if let rel = Self.relative(absolute, under: root) { existingRelative.insert(rel) }
            }
        }
        let primaryRootPath = allRoots[0].path(percentEncoded: false)
        let existingForPlanning = Set(existingRelative.map {
            (primaryRootPath as NSString).appendingPathComponent($0)
        })
        let basePlans = CopyPlan.planBatch(bundles: bundles, destinationRoot: allRoots[0],
                                           description: description, template: template,
                                           cardLabel: cardLabel, existingPaths: existingForPlanning)
        let plansPerRoot: [[BundlePlan]] = allRoots.enumerated().map { d, root in
            d == 0 ? basePlans : basePlans.map { Self.rebase($0, from: allRoots[0], to: root) }
        }

        var haltReason: String?
        var wasCancelled = false
        // Failures per destination, so "the NAS was offline" reads as one bad
        // mirror instead of a failed job.
        var failuresByRoot = [Int](repeating: 0, count: allRoots.count)
        let bundleCount = plansPerRoot.first?.count ?? 0

        outer: for i in 0..<bundleCount {
            if isCancelled() { wasCancelled = true; break }
            var primaryOK = true

            // Each destination gets its own error handling. A mirror failing must
            // not skip the mirrors *after* it and must not void the primary copy
            // that already landed: with one `do` around the whole loop, a NAS
            // dropping offline mid-job meant the third destination — a healthy
            // local SSD — received nothing at all, and every bundle was counted
            // failed even though the primary was complete and verified.
            // `copyBundle` rolls back only its own root, so partial state is
            // already contained per destination.
            for d in allRoots.indices {
                do {
                    // Only the primary (index 0) records the manifest — the
                    // mirrors are byte-identical.
                    try await copyBundle(plansPerRoot[d][i], index: indexes[d], recordManifest: d == 0, root: allRoots[d])
                } catch is CancellationError {
                    wasCancelled = true
                    break outer
                } catch let err as FileCopierError {
                    log(.error, rootLabel(d, of: allRoots) + err.description)
                    if d == 0 { primaryOK = false }
                    // A mismatch means the bytes on disk are not the bytes we
                    // read: stop the whole job, at every destination.
                    if case .verificationMismatch = err {
                        log(.error, "Halting job on verification mismatch.")
                        haltReason = "verification mismatch"
                        break outer
                    }
                    failuresByRoot[d] += 1
                    filesFailed += 1
                    continue
                } catch {
                    log(.error, rootLabel(d, of: allRoots) + "Bundle failed: \(error.localizedDescription)")
                    if d == 0 { primaryOK = false }
                    failuresByRoot[d] += 1
                    filesFailed += 1
                    continue
                }
            }

            completedBundles += 1
            // Only count what was actually hash-checked after the write, at the
            // destination the manifest attests to. The UI reports this number as
            // "already-verified … safe on disk", so incrementing it with
            // verification off — or after the primary copy failed — would make
            // the app vouch for bytes nothing ever read back.
            if verify && primaryOK { verifiedBundles += 1 }
            emitProgress(force: true)
        }

        let elapsed = Date().timeIntervalSince(startedAt)

        // A cancelled job still writes its manifest and log, below. The bundles
        // that completed are on disk and are *not* rolled back, so returning
        // early here left them with no integrity record at all — and a later
        // re-ingest dedup-skips them without a digest, so `verify` would report
        // success over zero files forever. Cancelling is routine; losing the
        // receipt for it is not acceptable.
        if wasCancelled || isCancelled() {
            wasCancelled = true
            log(.info, "Ingest cancelled after \(String(format: "%.1fs", elapsed)) — "
                     + "writing a manifest for the \(completedBundles) bundle\(completedBundles == 1 ? "" : "s") already copied.")
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
        if haltReason == nil, !wasCancelled, ejectAfter, let mountPoint = sourceMountPoint {
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
            partial: wasCancelled || haltReason != nil,
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
            archiveDestinations: archiveRoots,
            // The manifest's *resolved* stem, so the log keeps its name even if
            // the manifest had to take a collision suffix.
            baseName: manifestURL?.deletingPathExtension().lastPathComponent,
            directory: logDirectory
        )

        // Persist the hash cache — misses populated during this run stay hot.
        try? await cache.save()

        log(.info, "Complete: \(filesCopied) copied, \(filesSkipped) skipped, \(filesFailed) failed.")

        var failuresByDestination: [String: Int] = [:]
        for (d, root) in allRoots.enumerated() where failuresByRoot[d] > 0 {
            failuresByDestination[root.path(percentEncoded: false)] = failuresByRoot[d]
        }

        return CopyResult(
            bundleCount: totalBundles,
            filesCopied: filesCopied,
            filesSkipped: filesSkipped,
            filesFailed: filesFailed,
            failuresByDestination: failuresByDestination,
            totalBytes: landedBytes,
            elapsedSeconds: elapsed,
            primaryDestination: primaryRoot,
            logURL: logURL,
            manifestURL: manifestURL,
            wasEjected: didEject,
            halted: haltReason != nil,
            haltReason: haltReason,
            cancelled: wasCancelled
        )
    }

    /// `absolute` expressed relative to `root`, or nil if it isn't under it.
    /// Purely lexical: both strings are built from the same root spelling by
    /// `destinationDirectory` / `existingFilePaths`, and consulting the
    /// filesystem here would reintroduce the `/var` → `/private/var` mismatch
    /// those two go out of their way to avoid.
    static func relative(_ absolute: String, under root: URL) -> String? {
        let base = root.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard absolute.hasPrefix(prefix) else { return nil }
        return String(absolute.dropFirst(prefix.count))
    }

    /// The same bundle plan pointed at another destination root — identical
    /// relative paths, so every mirror is a true mirror and `heal` can find a
    /// file under any recorded root using the one path in the manifest.
    static func rebase(_ plan: BundlePlan, from oldRoot: URL, to newRoot: URL) -> BundlePlan {
        let files = plan.files.map { file -> PlannedFile in
            guard let rel = relative(file.destination.path(percentEncoded: false), under: oldRoot) else {
                return file
            }
            return PlannedFile(source: file.source,
                               destination: newRoot.appendingPathComponent(rel),
                               size: file.size,
                               role: file.role)
        }
        return BundlePlan(bundle: plan.bundle, files: files)
    }

    /// Prefixes a log line with the destination it concerns, but only when there
    /// is more than one — a single-destination job reads better unadorned.
    private func rootLabel(_ d: Int, of roots: [URL]) -> String {
        guard roots.count > 1 else { return "" }
        return d == 0 ? "[primary] " : "[mirror \(d): \(roots[d].lastPathComponent)] "
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
                    log(.skipped, "\(file.source.lastPathComponent) — already present as \(existingDuplicate.url.lastPathComponent)")
                    skippedInBundle += 1
                    if recordManifest {
                        bundleManifest.append(ManifestEntry(
                            name: file.source.lastPathComponent,
                            path: relativePath(of: existingDuplicate.url, under: root),
                            bytes: file.size,
                            // The digest the dedup match was *made* on, so a
                            // re-ingest of an already-complete card still writes
                            // a manifest that can be verified. Recording nil here
                            // meant `verify` skipped the entry entirely and
                            // reported success over zero files.
                            xxhash64: String(format: "%016llx", existingDuplicate.hash),
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
