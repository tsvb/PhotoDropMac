import Foundation

/// Brings a mirror up to date with a library that is already verified.
///
/// **Why this exists.** The 3-2-1 story has a hole in the middle of its most
/// common shape: laptop in the field, NAS at home. A mirror that isn't mounted
/// when the card is ingested has no way to ever catch up. `heal` is deliberately
/// report-only and looks the wrong way round — it treats recorded mirrors as
/// *recovery sources* for a damaged library, so it would offer the lagging NAS
/// as a place to restore *from*. `verify` only reports. Re-running the whole
/// ingest needs the card, which by then is back in the camera, reformatted.
///
/// So: read the library's own manifests for what should exist, copy anything the
/// mirror is missing, verify it, and write the mirror a manifest of its own so it
/// becomes verifiable in its own right.
///
/// **This is the one command that writes to a destination without a card**, so
/// its limits are deliberate and narrow:
///
/// - It only ever *adds*. A file already at the mirror is verified and left
///   alone; a mismatch is **reported, never overwritten**. Two disagreeing copies
///   is exactly the situation where picking a winner automatically is how the
///   good copy dies, and `VerifyEngine` already refuses to arbitrate between
///   conflicting records for the same reason.
/// - It reads the library, not the card, so the source is the copy that was
///   already hash-verified when it landed.
/// - It refuses a mirror that is inside the library or vice versa, the same
///   topology rule the ingest applies.
/// - It stops the way an ingest stops. `isCancelled` is polled at every file
///   boundary and between chunks inside `FileCopier`, and a cancelled run still
///   writes the mirror's manifest for what landed, marked `partial`. The CLI
///   wires the termination signals to it (`GracefulStop`); it shipped without
///   that, and a Ctrl-C mid-file left a truncated file the next sync could only
///   report as a CONFLICT it must not touch.
/// - **A synced mirror is not one `heal` will search unaided.** The library's
///   manifests were written by the ingest and record only the roots that job
///   wrote; `heal` refuses unrecorded roots by design (the mirror gate in
///   `VerifyEngine.build`). `Outcome.recordedInLibrary` says which case this
///   is, so the CLI can tell the user to pass `--mirror` while the fact is
///   fresh. Writing the mirror *into* the library's records would mean writing
///   to the library, which this command promises never to do.
enum SyncEngine {

    struct Outcome: Sendable {
        /// Files that were missing at the mirror and have now been copied and
        /// verified.
        var copied: Int = 0
        /// Files already present at the mirror whose content matches.
        var alreadyPresent: Int = 0
        /// Files present at the mirror whose content does **not** match the
        /// library's record. Never touched — reported for the user to resolve.
        var conflicting: [String] = []
        /// Files the library's manifest records that are missing from the
        /// *library itself*, so there is nothing to copy from.
        var missingAtSource: [String] = []
        /// Files that could not be copied, with the reason.
        var failed: [(path: String, reason: String)] = []
        var bytesCopied: Int64 = 0
        /// The manifest written at the mirror, if one could be written.
        var manifestURL: URL?
        /// The run was interrupted before every item was examined. What did
        /// land is verified and in the mirror's manifest, marked partial.
        var cancelled = false
        /// Whether the library's own manifests name this mirror as one of their
        /// destinations — i.e. whether `heal <library>` will search it without
        /// being told to. See the type comment.
        var recordedInLibrary = false

        /// Nothing is wrong: everything the library records is now at the mirror.
        var allGood: Bool {
            conflicting.isEmpty && failed.isEmpty && missingAtSource.isEmpty
        }
    }

    enum Refusal: Error, CustomStringConvertible {
        case unreadableLibrary(URL)
        case noManifests(URL)
        case mirrorMissing(URL)
        case overlapping(String)

        var description: String {
            switch self {
            case let .unreadableLibrary(url):
                return "Could not read the library at “\(url.path)”."
            case let .noManifests(url):
                return "No PhotoDrop manifest found under “\(url.path)”, so there is no record of what should be mirrored."
            case let .mirrorMissing(url):
                return "The mirror “\(url.path)” does not exist. Mount it, or create the folder first — sync will not create a whole new library tree."
            case let .overlapping(message):
                return message
            }
        }
    }

    /// - Parameters:
    ///   - library: the verified library to mirror *from*.
    ///   - mirror: the destination to bring up to date. Must already exist, for
    ///     the same reason `--to` must: creating it would silently manufacture a
    ///     library at a typo'd path.
    ///   - verify: re-read each copy from the device and check it, as the ingest
    ///     does.
    static func run(
        library: URL,
        mirror: URL,
        verify: Bool = true,
        isCancelled: () -> Bool = { false },
        onProgress: (VerifyProgress) -> Void = { _ in },
        onLog: (LogEntry) -> Void = { _ in }
    ) throws -> Outcome {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: library.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Refusal.unreadableLibrary(library)
        }
        guard fm.fileExists(atPath: mirror.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Refusal.mirrorMissing(mirror)
        }
        let problems = DestinationTopology.check(source: library, roots: [mirror])
        if let first = problems.first { throw Refusal.overlapping(first.message) }

        // What *should* be there, from the library's own records — the same
        // trust-checked path `verify` uses, so the containment rule, the conflict
        // rule and the mirror gate are all inherited rather than re-implemented.
        let plan = VerifyEngine.build(target: library)
        guard plan.manifestCount > 0 else { throw Refusal.noManifests(library) }

        var outcome = Outcome()
        outcome.recordedInLibrary = libraryRecords(mirror: mirror, in: library)
        var entries: [ManifestEntry] = []
        let startedAt = Date()
        let total = plan.items.count

        func log(_ kind: LogEntry.Kind, _ line: String, signature: UInt64? = nil) {
            onLog(LogEntry(timestamp: Date(), kind: kind, line: line, signature: signature))
        }

        if plan.partialManifests > 0 {
            log(.info, "\(plan.partialManifests) of \(plan.manifestCount) manifest(s) are marked partial — "
                     + "this library is itself known to be incomplete, so the mirror will match it, not the card.")
        }

        for (i, item) in plan.items.enumerated() {
            if isCancelled() { outcome.cancelled = true; break }
            onProgress(VerifyProgress(total: total, checked: i + 1, currentFile: item.name))

            let destination = mirror.appendingPathComponent(item.relPath)

            // Present already? Verify rather than assume, and never overwrite.
            if fm.fileExists(atPath: destination.path) {
                if let actual = try? XxHash64.hash(fileAt: destination, bypassCache: true),
                   actual == item.expected {
                    outcome.alreadyPresent += 1
                    entries.append(ManifestEntry(
                        name: item.name,
                        path: item.relPath,
                        bytes: Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0),
                        xxhash64: String(format: "%016llx", item.expected),
                        status: "skipped"))
                } else {
                    // Reported, never resolved. Two disagreeing copies is where an
                    // automatic winner kills the good one.
                    outcome.conflicting.append(item.relPath)
                    log(.error, "\(item.relPath) — already at the mirror with different content; left untouched.")
                }
                continue
            }

            // The library's own copy is the source. If it isn't there, the
            // library is damaged and this is a job for `heal`, not `sync`.
            guard fm.fileExists(atPath: item.url.path) else {
                outcome.missingAtSource.append(item.relPath)
                log(.error, "\(item.relPath) — recorded in the manifest but missing from the library itself.")
                continue
            }

            do {
                let hash = try FileCopier.copyAndHash(
                    source: item.url, destination: destination, isCancelled: isCancelled
                ) { _ in }
                guard hash == item.expected else {
                    // The library no longer holds what its manifest says. Copying
                    // it onward would propagate the damage into the one place
                    // that might still have had a good copy.
                    try? fm.removeItem(at: destination)
                    outcome.conflicting.append(item.relPath)
                    log(.error, "\(item.relPath) — the library's copy no longer matches its own manifest; not mirrored.")
                    continue
                }
                if verify { try FileCopier.verify(file: destination, expectedHash: hash) }
                _ = FileChecksumXattr.stamp(hash, on: destination)

                outcome.copied += 1
                outcome.bytesCopied += Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                entries.append(ManifestEntry(
                    name: item.name,
                    path: item.relPath,
                    bytes: Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0),
                    xxhash64: String(format: "%016llx", hash),
                    status: "copied"))
                log(verify ? .verified : .copied, "\(item.relPath)", signature: verify ? hash : nil)
            } catch is CancellationError {
                // `copyAndHash` removed its own partial, so nothing is left at
                // the mirror for the next run to mistake for a conflict. Not a
                // failure: the user asked to stop, and the file is simply not
                // there yet.
                outcome.cancelled = true
                break
            } catch {
                outcome.failed.append((item.relPath, "\(error)"))
                log(.error, "\(item.relPath) — \(error)")
            }
        }

        _ = FileCopier.fullSyncVolume(at: mirror)

        // The mirror gets a manifest of its own, which is what makes it
        // verifiable at all — `verify <mirror>` exits 2 without one, and
        // `--xattr` cannot detect absence.
        let manifest = Manifest(
            schema: Manifest.schemaID,
            app: Manifest.appName,
            createdAt: startedAt,
            source: library.lastPathComponent,
            primaryDestination: mirror.path(percentEncoded: false),
            archiveDestination: library.path(percentEncoded: false),
            destinations: [mirror.path(percentEncoded: false), library.path(percentEncoded: false)],
            verified: verify,
            // Honest about its own completeness on the same terms as an ingest.
            partial: !outcome.allGood || outcome.cancelled,
            filesCopied: outcome.copied,
            filesSkipped: outcome.alreadyPresent,
            filesFailed: outcome.failed.count,
            totalBytes: entries.reduce(Int64(0)) { $0 + $1.bytes },
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            files: entries
        )
        // A manifest is written when this run changed something, or when the
        // mirror has none yet — which is what makes it verifiable on its own.
        // A no-op sync writing one anyway would file a new record on every run,
        // so a nightly catch-up job would fill the folder with identical
        // manifests and make the real ones harder to find.
        let hasManifestAlready = !ManifestWriter.manifestURLs(near: mirror).isEmpty
        if outcome.copied > 0 || !outcome.allGood || !hasManifestAlready {
            outcome.manifestURL = ManifestWriter.write(manifest, intoRoot: mirror,
                                                       stamp: startedAt, kind: "sync")
        }
        return outcome
    }

    /// Whether any manifest under `library` names `mirror` among its
    /// destinations. Compared on standardized paths: a recorded root is a string
    /// chosen by whoever wrote the manifest, and a trailing slash or a `/var`
    /// spelling must not read as a different folder.
    static func libraryRecords(mirror: URL, in library: URL) -> Bool {
        let wanted = mirror.standardizedFileURL.path(percentEncoded: false)
        for url in ManifestWriter.manifestURLs(near: library) {
            guard let data = try? Data(contentsOf: url),
                  let manifest = ManifestWriter.decode(data) else { continue }
            // Older manifests carry no `destinations`; the same fallback
            // `VerifyEngine.build` applies.
            let recordedRoots = manifest.destinations
                ?? [manifest.primaryDestination] + [manifest.archiveDestination].compactMap { $0 }
            for recorded in recordedRoots {
                let path = URL(fileURLWithPath: recorded, isDirectory: true)
                    .standardizedFileURL.path(percentEncoded: false)
                if path == wanted { return true }
            }
        }
        return false
    }
}
