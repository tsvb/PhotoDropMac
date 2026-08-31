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
    /// Every bundle that failed, with the destination it failed at and why.
    ///
    /// `CopyResult` carried counts alone, and the per-file reasons existed only
    /// as log lines — which the detail pane stops rendering the moment a job
    /// leaves `.running`, and which `Copier.reset()` clears on dismiss. So the
    /// entire in-app account of a run that lost 40 of 500 files was "40 files
    /// failed — see log for details", and dismissing the sheet destroyed the
    /// detail. A failure the user cannot read is a failure they cannot act on.
    ///
    /// Bounded: a job whose destination went away fails every remaining bundle,
    /// and a 2,000-entry array behind a `Hashable` result that crosses actor
    /// boundaries is not worth the fidelity. `failuresByDestination` keeps the
    /// true count; this keeps the readable evidence.
    let failedFiles: [FailedFile]
    /// Folders under the primary root that already held this card's photos, when
    /// they are *not* the folders this job planned to write.
    ///
    /// Distinguishes "this card is already in your library" from "this card is
    /// already in your library, under a different name than the one you just
    /// typed". Both produce `filesCopied == 0`, and the second used to be
    /// reported as the first — so a corrected description looked like it had
    /// been applied when nothing had moved.
    let duplicatesFoundElsewhere: [String]
    let totalBytes: Int64
    let elapsedSeconds: Double
    let primaryDestination: URL
    let logURL: URL?
    let manifestURL: URL?
    /// Destination roots whose verification manifest could **not** be written.
    ///
    /// `ManifestWriter.write` returns `nil` on four separate failures and the
    /// engine used to discard that, so a job could copy every file, verify every
    /// file, report `✓ Ingest complete`, exit 0 and eject the card while leaving
    /// a library with no integrity record at all. The manifest is the product;
    /// a job that couldn't write one did not fully succeed, and every consumer —
    /// the CLI's exit code, the completion sheet, the eject gate — now has to be
    /// able to see that.
    let manifestFailures: [String]
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

    /// One bundle's failure at one destination.
    struct FailedFile: Sendable, Equatable, Hashable, Identifiable {
        var id: String { "\(destination)|\(name)" }
        /// The source file's name, which is what the user recognizes — the
        /// destination name may have been templated into something else.
        let name: String
        /// The destination root it failed at, so a mirror-only failure is
        /// legible as such.
        let destination: String
        let reason: String
    }

    /// The cap on `failedFiles`. Past this the list is truncated and
    /// `failuresByDestination` remains the authority on how many there were.
    static let maxRecordedFailures = 200

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
    /// Manifest entries **per destination root**, parallel to `allRoots`.
    ///
    /// Previously only the primary recorded entries, on the reasoning that a
    /// mirror is byte-identical. It is byte-identical only when it was fully
    /// written — and nothing recorded whether it was. A 3-destination job whose
    /// NAS dropped offline at bundle 40 of 500 wrote one manifest saying
    /// `partial: false` with `destinations: [lib, nas, ssd]` and 500 verified
    /// entries, and no verification surface could contradict it: a mirror root has
    /// no manifest folder, so `verify <mirror>` exits 2 "no manifest found", and
    /// `verify --xattr` enumerates the files that *are* there and so can never
    /// detect absence. Recording per root makes each destination self-describing
    /// — a root's manifest lists exactly what landed *there*, by construction.
    private var manifestEntriesByRoot: [[ManifestEntry]] = []
    private var logEntries: [LogEntry] = []
    private var lastProgressTick: Date
    /// Roots whose volume rejected the checksum xattr, so the notice is logged
    /// once per destination instead of once per file (or, as before, never).
    private var xattrUnsupportedRoots = Set<Int>()
    /// The **deduped** destination roots for this run, in the order every
    /// `destination:` index refers to.
    ///
    /// Held as a property because `copyBundle` labels its log lines by that index
    /// and previously reconstructed the list as `[primaryRoot] + archiveRoots` —
    /// the *un-deduped* one. With any destination collapsed as a duplicate the
    /// two lists differ in length, so the "this volume does not support checksum
    /// attributes" notice named a different mirror than the one it was about.
    private var resolvedRoots: [URL] = []
    /// See `CopyResult.failedFiles`. Capped at `CopyResult.maxRecordedFailures`.
    private var failedFiles: [CopyResult.FailedFile] = []
    /// Folders under the primary root where duplicates were found that this job
    /// would have filed somewhere else. See `CopyResult.duplicatesFoundElsewhere`.
    private var duplicatesFoundElsewhere: Set<String> = []

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

        // Hold the machine awake for the whole job, including the tail: the
        // manifest write, the volume barrier and the eject all still have to
        // happen after the last byte. Released by `deinit` when this scope ends,
        // on every path out including a throw or a cancel.
        let awake = PowerAssertion(reason: "PhotoDrop is copying photos from a card")
        defer { awake.release() }

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
        manifestEntriesByRoot = Array(repeating: [], count: allRoots.count)
        resolvedRoots = allRoots

        // Refuse a topology where the trees overlap. `dedupedRoots` above collapses
        // roots that are the *same* folder; this catches roots that *contain* one
        // another, and a destination that contains the source. All three make the
        // dedup index match files against copies of themselves, which reads as a
        // clean all-duplicate job — nothing copied, nothing failed, no halt — and
        // then ejects the card. See DestinationTopology for the measured cases.
        // Checked here rather than only in the UI because the engine takes roots
        // from any caller, and the CLI has no preflight at all.
        let topologyProblems = DestinationTopology.check(
            source: sourceMountPoint.map { URL(fileURLWithPath: $0, isDirectory: true) },
            roots: allRoots
        )
        if let first = topologyProblems.first {
            for problem in topologyProblems { log(.error, problem.message) }
            log(.error, "Refusing the job: nothing was copied and the card was not ejected.")
            return refusedResult(reason: first.shortReason, allRoots: allRoots)
        }

        log(.info, "Starting ingest: \(bundles.count) bundles, \(totalBytes.formatted(.byteCount(style: .file)))\(allRoots.count > 1 ? " × \(allRoots.count) destinations" : "")")

        // Say how many photos are being filed by file date rather than by the
        // camera's own timestamp. `dateSource` was recorded on every scan and
        // read nowhere, which made this invisible — and it is the one signal that
        // exposes a wrong date folder. A file's mtime is the *copy* time if the
        // card has ever passed through another machine, so these are exactly the
        // photos most likely to be filed under a day nothing was shot on.
        let fallbackDated = bundles.filter { $0.primary.dateSource == .fileModification }.count
        if fallbackDated > 0 {
            log(.info, "\(fallbackDated) of \(bundles.count) photo\(bundles.count == 1 ? "" : "s") "
                     + "have no capture date in their metadata and are filed by file date instead.")
        }
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
                    try await copyBundle(plansPerRoot[d][i], index: indexes[d], destination: d, root: allRoots[d])
                } catch is CancellationError {
                    wasCancelled = true
                    break outer
                } catch let err as FileCopierError {
                    log(.error, rootLabel(d, of: allRoots) + err.description)
                    recordFailure(bundle: plansPerRoot[d][i], root: allRoots[d], reason: err.description)
                    if d == 0 { primaryOK = false }
                    // A mismatch means the bytes on disk are not the bytes we
                    // read: stop the whole job, at every destination.
                    if case .verificationMismatch = err {
                        log(.error, "Halting job on verification mismatch.")
                        haltReason = "verification mismatch"
                        break outer
                    }
                    // **The source going away is a job-level fault, not a
                    // per-bundle one.** A bumped reader, a bus-powered drive
                    // losing power to idle sleep, or someone pulling the wrong
                    // card at bundle 100 of 2000 produced 1,900 identical
                    // "could not be opened" lines — 5,700 with mirrors — and a
                    // user with no way to tell from the log what had happened.
                    // Every remaining bundle is guaranteed to fail for the same
                    // reason, so stop and say so once.
                    if isSourceSide(err), sourceIsGone() {
                        log(.error, "The source is no longer readable — the card may have been removed "
                                  + "or the drive may have gone to sleep. Stopping here; "
                                  + "\(bundleCount - i - 1) bundle(s) were not copied.")
                        haltReason = "the card was removed"
                        failuresByRoot[d] += 1
                        filesFailed += 1
                        break outer
                    }
                    failuresByRoot[d] += 1
                    filesFailed += 1
                    continue
                } catch {
                    log(.error, rootLabel(d, of: allRoots) + "Bundle failed: \(error.localizedDescription)")
                    recordFailure(bundle: plansPerRoot[d][i], root: allRoots[d],
                                  reason: error.localizedDescription)
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

        // The device flush and the eject both happen **after** the manifest and
        // log are written; see the end of this function. They used to run here,
        // which put the one irreversible act in the job (the eject) ahead of the
        // receipt that proves the job was worth ejecting for. Nothing that
        // happens after a card leaves the reader can be recovered by re-reading
        // it, so the receipt has to exist and be durable first.

        // Reported size = bytes that actually landed in the primary library (the
        // sum of its manifest entries), not the progress counter `bytesCopied`,
        // which counts every pass (≈N× under mirrors).
        let landedBytes = manifestEntriesByRoot[0].reduce(Int64(0)) { $0 + $1.bytes }

        // One manifest **per destination root**, each listing only what landed at
        // that root and each marked `partial` on its own evidence. Writing a
        // single manifest at the primary meant a mirror had no integrity record
        // at all and no way to acquire one; see `manifestEntriesByRoot`.
        //
        // `partial` now also accounts for failures. It read
        // `wasCancelled || haltReason != nil`, so a job that lost 300 files to an
        // offline NAS recorded `partial: false` — a durable, confident claim of
        // completeness over an incomplete tree.
        var manifestURLs: [URL?] = []
        for (d, root) in allRoots.enumerated() {
            let entries = manifestEntriesByRoot[d]
            let manifest = Manifest(
                schema: Manifest.schemaID,
                app: Manifest.appName,
                createdAt: startedAt,
                source: sourceMountPoint.map { URL(fileURLWithPath: $0).lastPathComponent },
                // Each manifest describes the root it sits in, so `heal` reading a
                // mirror's manifest treats that mirror as the library and the
                // other roots as its recovery sources.
                primaryDestination: root.path(percentEncoded: false),
                archiveDestination: allRoots.first { $0 != root }?.path(percentEncoded: false),
                destinations: allRoots.map { $0.path(percentEncoded: false) },
                verified: verify,
                partial: wasCancelled || haltReason != nil || failuresByRoot[d] > 0,
                // Counts derived from *this root's* entries, so a manifest never
                // describes work done somewhere else. The job-wide totals stay in
                // `CopyResult`, where they belong.
                filesCopied: entries.lazy.filter { $0.status != "skipped" }.count,
                filesSkipped: entries.lazy.filter { $0.status == "skipped" }.count,
                filesFailed: failuresByRoot[d],
                totalBytes: entries.reduce(Int64(0)) { $0 + $1.bytes },
                elapsedSeconds: elapsed,
                files: entries
            )
            manifestURLs.append(ManifestWriter.write(manifest, intoRoot: root, stamp: startedAt))
        }
        let manifestURL = manifestURLs.first ?? nil
        if manifestURL != nil {
            let written = manifestURLs.compactMap { $0 }.count
            log(.info, written > 1
                ? "Verification manifests written to “\(ManifestWriter.folderName)” at \(written) destinations."
                : "Verification manifest written to “\(ManifestWriter.folderName)”.")
        }

        // **A manifest that did not get written is a failure, and it used to be
        // silent.** `ManifestWriter.write` answers `nil` on four distinct
        // failures — the folder can't be created, the encode fails, the name
        // can't be claimed, the write throws — and the only branch here logged
        // the *successes*. So a primary that filled up on the last bundle, or a
        // read-only `PhotoDrop Manifests` folder, produced `filesFailed == 0`,
        // an opened eject gate, "✓ Ingest complete" and exit 0 over a library of
        // files nothing can ever verify. The receipt is the product; failing to
        // write it is not a footnote.
        var manifestFailures: [String] = []
        for (d, root) in allRoots.enumerated() where manifestURLs[d] == nil {
            manifestFailures.append(root.path(percentEncoded: false))
            log(.error, rootLabel(d, of: allRoots)
                     + "Could not write the verification manifest for this destination. "
                     + "The files are copied, but nothing here records their checksums.")
        }

        // Persist the hash cache — misses populated during this run stay hot.
        try? await cache.save()

        // One F_FULLFSYNC per destination volume, now that every file is fsync'd
        // **and the manifest is written**. This used to run before the manifest,
        // so the photos were durable and the receipt for them was not: `.atomic`
        // gives rename-atomicity, not durability, and after `rename(2)` returns
        // both the data and the directory entry can still be in the page cache.
        // A power loss in the seconds after a job finished left a good library
        // with no manifest, and `verify` then reported exit 2 "no manifest
        // found" over it forever.
        //
        // The old `filesCopied > 0` gate is gone for the same reason: an
        // all-duplicate re-ingest copies nothing and still writes a manifest,
        // and that manifest needs the barrier as much as any other.
        if filesCopied > 0 || manifestURLs.contains(where: { $0 != nil }) {
            log(.info, "Flushing destinations to disk…")
            for (d, root) in allRoots.enumerated() where !FileCopier.fullSyncVolume(at: root) {
                // Named per volume rather than once per job: a user with a single
                // SMB mirror saw the same anonymous warning on every ingest and
                // had no way to tell which destination it was about, which is how
                // a warning becomes noise.
                log(.error, rootLabel(d, of: allRoots)
                         + "Could not force a device-cache flush here; the copies are written "
                         + "but may not survive an immediate power loss until the OS flushes them.")
            }
        }

        // Ejecting is the one irreversible act in the job. It is gated on
        // halt/cancel/failures — a run that lost files to a full disk or a
        // permission error must not put the only remaining copy out of reach —
        // and now also on the receipt existing: ejecting after a failed manifest
        // write strands a library nothing can verify while the source is still
        // in the reader. Failures are recoverable exactly as long as the card is
        // still mounted.
        var didEject = false
        if haltReason == nil, !wasCancelled, filesFailed == 0, manifestFailures.isEmpty,
           ejectAfter, let mountPoint = sourceMountPoint {
            log(.info, "Ejecting card…")
            do {
                try await DriveEjector.eject(mountPoint: mountPoint)
                didEject = true
                log(.info, "Card ejected — safe to remove.")
            } catch {
                log(.error, "Eject failed: \(error.localizedDescription)")
            }
        } else if ejectAfter, !manifestFailures.isEmpty, haltReason == nil, !wasCancelled, filesFailed == 0 {
            log(.info, "Card not ejected: the verification manifest could not be written. "
                     + "The card is still mounted, so the ingest can be re-run.")
        }

        log(.info, "Complete: \(filesCopied) copied, \(filesSkipped) skipped, \(filesFailed) failed.")

        // The log is written **last**, so it is the only artifact that can record
        // the flush, the eject and the final tally. Written before them, it was
        // an audit trail that stopped just short of the two events a reader most
        // wants to find in it.
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
            failedFiles: failedFiles,
            duplicatesFoundElsewhere: duplicatesFoundElsewhere.sorted(),
            totalBytes: landedBytes,
            elapsedSeconds: elapsed,
            primaryDestination: primaryRoot,
            logURL: logURL,
            manifestURL: manifestURL,
            manifestFailures: manifestFailures,
            wasEjected: didEject,
            halted: haltReason != nil,
            haltReason: haltReason,
            cancelled: wasCancelled
        )
    }

    /// A job refused before any file was touched: halted, nothing copied, no
    /// manifest. Deliberately writes **no** manifest — a manifest is a receipt for
    /// bytes that landed, and refusing means none did; writing one into a root
    /// that overlaps the source would also plant a record inside the card.
    /// The log *is* written, so the refusal is in the audit trail.
    private func refusedResult(reason: String, allRoots: [URL]) -> CopyResult {
        let elapsed = Date().timeIntervalSince(startedAt)
        let logURL = JobLogger.write(
            entries: logEntries,
            startedAt: startedAt,
            elapsedSeconds: elapsed,
            primaryDestination: primaryRoot,
            archiveDestinations: archiveRoots,
            baseName: nil,
            directory: logDirectory
        )
        return CopyResult(
            bundleCount: totalBundles,
            filesCopied: 0,
            filesSkipped: 0,
            filesFailed: 0,
            failuresByDestination: [:],
            failedFiles: [],
            duplicatesFoundElsewhere: [],
            totalBytes: 0,
            elapsedSeconds: elapsed,
            primaryDestination: primaryRoot,
            logURL: logURL,
            manifestURL: nil,
            // A refusal writes no manifest *by design* — no bytes landed, so
            // there is nothing to attest to. That is not a manifest failure.
            manifestFailures: [],
            wasEjected: false,
            halted: true,
            haltReason: reason,
            cancelled: false
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

    /// Is this error about a file on the *source*, rather than a destination?
    ///
    /// Compared by path components against the source root — never by string
    /// prefix, for the reason `DestinationTopology` spells out: `/Volumes/CARD2`
    /// is not inside `/Volumes/CARD`.
    private func isSourceSide(_ err: FileCopierError) -> Bool {
        guard let mountPoint = sourceMountPoint else { return false }
        let root = URL(fileURLWithPath: mountPoint, isDirectory: true)
            .standardizedFileURL.pathComponents
        let file = err.url.standardizedFileURL.pathComponents
        guard file.count > root.count else { return false }
        return Array(file.prefix(root.count)) == root
    }

    /// Has the source stopped being readable altogether?
    ///
    /// Checked only after a source-side failure, so the cost is paid once per
    /// fault rather than once per file. `isReadableFile` as well as existence:
    /// an unmounted volume can leave its mount point behind as an empty,
    /// unreadable directory.
    private func sourceIsGone() -> Bool {
        guard let mountPoint = sourceMountPoint else { return false }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: mountPoint, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isReadableFile(atPath: mountPoint) else { return true }
        return (try? fm.contentsOfDirectory(atPath: mountPoint)) == nil
    }

    private func recordFailure(bundle: BundlePlan, root: URL, reason: String) {
        guard failedFiles.count < CopyResult.maxRecordedFailures else { return }
        failedFiles.append(CopyResult.FailedFile(
            name: bundle.bundle.primary.url.lastPathComponent,
            destination: root.path(percentEncoded: false),
            reason: reason
        ))
    }

    /// Prefixes a log line with the destination it concerns, but only when there
    /// is more than one — a single-destination job reads better unadorned.
    private func rootLabel(_ d: Int, of roots: [URL]) -> String {
        guard roots.count > 1 else { return "" }
        return d == 0 ? "[primary] " : "[mirror \(d): \(roots[d].lastPathComponent)] "
    }

    // MARK: - Per-bundle copy (all-or-nothing, with rollback)

    private func copyBundle(_ plan: BundlePlan, index: DestinationIndex, destination d: Int, root: URL) async throws {
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
                    // **Where** the duplicate lives, when that is not where this
                    // job would have put it.
                    //
                    // Dedup matches content anywhere under the root — deliberately,
                    // so a renamed earlier import is still found. The consequence
                    // is the most likely shoot-day misstep in the app: ingest a
                    // card with the description blank, realise you wanted
                    // "Smith Wedding", type it, ingest again. Every file matches
                    // its twin in the old folder, nothing is copied, the new
                    // folder is never created, and the sheet says "Everything was
                    // already there — nothing new to copy." The user reads that as
                    // done and reformats the card, and the library is organised
                    // under a name they explicitly rejected.
                    //
                    // Only the primary root is tracked: a mirror lagging behind is
                    // a different situation with its own reporting.
                    if d == 0 {
                        let foundIn = existingDuplicate.url.deletingLastPathComponent()
                        let plannedIn = file.destination.deletingLastPathComponent()
                        if foundIn.standardizedFileURL != plannedIn.standardizedFileURL,
                           let rel = Self.relative(foundIn.path(percentEncoded: false), under: root) {
                            duplicatesFoundElsewhere.insert(rel)
                        }
                    }
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
                // Best-effort by design — exFAT, FAT and some SMB shares have
                // nowhere to put it. The *result* used to be discarded, which
                // made "this whole mirror carries no checksums" indistinguishable
                // from success; say it once per root instead, since `verify
                // --xattr` is otherwise the only tool that would have noticed and
                // it reports an unstamped tree as nothing to check.
                if !FileChecksumXattr.stamp(copyHash, on: dest), xattrUnsupportedRoots.insert(d).inserted {
                    log(.info, rootLabel(d, of: resolvedRoots)
                             + "This volume does not support checksum attributes; the manifest is the record for it.")
                }

                bundleManifest.append(ManifestEntry(
                    name: file.source.lastPathComponent,
                    path: relativePath(of: dest, under: root),
                    bytes: file.size,
                    xxhash64: String(format: "%016llx", copyHash),
                    status: verify ? "verified" : "copied"
                ))
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
        // `filesCopied`/`filesSkipped` count every (file × destination) write, as
        // they always have; the per-destination breakdown lives in
        // `manifestEntriesByRoot`, which each root's own manifest is derived from.
        filesCopied += copiedInBundle
        filesSkipped += skippedInBundle
        manifestEntriesByRoot[d].append(contentsOf: bundleManifest)
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
