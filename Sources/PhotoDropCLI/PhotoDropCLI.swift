import ArgumentParser
import Foundation
import os

@main
struct PhotoDropCommand: AsyncParsableCommand {
    /// Read from the bundle rather than written out here.
    ///
    /// This was a literal, and it had drifted two releases behind
    /// `MARKETING_VERSION` — `photodrop --version` reported 0.1.3 while the app
    /// it ships inside was 0.2.1. For a tool whose product is "these bytes are
    /// the bytes that came off the card", a binary that misreports itself
    /// undermines the manifest it just signed: a support conversation cannot
    /// establish which code produced a given receipt.
    ///
    /// `Bundle.main` is the app bundle when the CLI runs from inside it (the
    /// normal case — it is embedded at `Contents/MacOS/photodrop`). Standalone,
    /// there is no Info.plist, hence the fallback.
    static let toolVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown (built without a bundle)"
    }()

    static let configuration = CommandConfiguration(
        commandName: "photodrop",
        abstract: "Verify and ingest photo libraries from the command line.",
        version: PhotoDropCommand.toolVersion,
        subcommands: [Verify.self, Ingest.self, Sync.self, Heal.self, Layouts.self]
    )
}

// MARK: - heal

struct Heal: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report which damaged/missing files can be restored from a mirror (read-only — never writes to the library)."
    )

    @Argument(help: "A library folder or a manifest .json.")
    var target: String

    @Flag(name: .long, help: "Emit a JSON report instead of human-readable text.")
    var json = false

    @Option(name: .long, help: "Write a reviewable restore script here. PhotoDrop never touches the library itself — you run the script.")
    var script: String?

    /// A manifest's `destinations[]` is untrusted, so a recorded mirror is only
    /// searched when it carries the `PhotoDrop Manifests/` folder every real
    /// destination has — otherwise a planted manifest turns `heal` into a content
    /// oracle over any directory the user can read. This is the escape hatch for
    /// a mirror written before mirrors carried their own manifests: the *user's*
    /// word, which is the only trustworthy source here.
    @Option(name: .long, parsing: .singleValue,
            help: "Also search this mirror root, even if it carries no PhotoDrop manifest. Repeatable.")
    var mirror: [String] = []

    func run() throws {
        let url = URL(fileURLWithPath: target)
        let showProgress = !json && isatty(FileHandle.standardError.fileDescriptor) != 0

        guard let report = HealEngine.run(
            target: url,
            allowedMirrorRoots: mirror.map { URL(fileURLWithPath: $0, isDirectory: true) },
            onProgress: { progress in
                guard showProgress else { return }
                FileHandle.standardError.write(Data("\r  checking \(progress.checked)/\(progress.total)…".utf8))
            }) else {
            CLIOutput.error("Heal scan was interrupted.")
            throw ExitCode(2)
        }
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }

        guard report.total > 0 else {
            CLIOutput.error(CLIOutput.nothingToCheck(at: url, manifestCount: report.manifestCount))
            throw ExitCode(2)
        }

        print(json ? CLIOutput.healJSON(report) : CLIOutput.healHuman(report))

        // A failure to write the script must not change what `heal` says about
        // the *library*. It used to `throw ExitCode(2)`, so a damaged library
        // whose script path already existed reported "could not verify / error"
        // instead of "issues found" — collapsing exactly the distinction
        // `ScheduledVerification` branches on when it decides which alarm to
        // raise. Report the write failure, then fall through to the real verdict.
        var scriptFailed = false
        if let script, !report.recoverable.isEmpty {
            // Keep the script out of the library it describes. `heal` promises to
            // be report-only and never to write to the library; nothing enforced
            // that for its own output, so `--script "<lib>/PhotoDrop Manifests/x.json"`
            // dropped a mode-0755 shell script into the folder that holds the
            // library's integrity records.
            let scriptURL = URL(fileURLWithPath: script)
            if DestinationTopology.contains(url, scriptURL) {
                CLIOutput.error("Refused to write the restore script inside \(CLIOutput.safe(url.path)) — "
                              + "heal never writes to the library it is reporting on. Choose a path outside it.")
                scriptFailed = true
            } else {
                // Create with O_EXCL rather than `write(toFile:atomically:)`, which
                // replaces whatever is already at the path — the one destructive act
                // in an otherwise strictly report-only command. The path is the
                // user's explicit choice, so silently writing somewhere else would be
                // worse than refusing; say so and let them decide.
                let fd = open(script, O_WRONLY | O_CREAT | O_EXCL, 0o755)
                if fd >= 0 {
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    try handle.write(contentsOf: Data(HealEngine.restoreScript(report).utf8))
                    try handle.close()
                    CLIOutput.error("Wrote restore script to \(CLIOutput.safe(script)) — review it, then run it yourself.")
                } else {
                    CLIOutput.error(errno == EEXIST
                        ? "Refused to overwrite \(CLIOutput.safe(script)) — remove it or choose another path."
                        : "Could not write \(CLIOutput.safe(script)): \(String(cString: strerror(errno)))")
                    scriptFailed = true
                }
            }
        }

        if !report.allHealthy { throw ExitCode(1) }   // 0 = healthy, 1 = damage found
        if scriptFailed { throw ExitCode(2) }         // healthy library, but we couldn't write the script
    }
}

// MARK: - layouts

/// Lists the built-in folder layouts and exactly what each produces. The sample
/// paths are rendered by the same code the copy engine uses, so this cannot
/// advertise a shape the ingest wouldn't build.
struct Layouts: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the built-in folder layouts usable with `ingest --layout`."
    )

    func run() throws {
        for layout in FolderLayout.builtIn {
            print(layout.name)
            print("    …/\(layout.samplePath())")
            print("    \(layout.detail)")
        }
    }
}

// MARK: - ingest

struct Ingest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ingest photos from a card into a date-organized library (hash-verified)."
    )

    @Option(name: .long, help: "Memory card or source folder to ingest from.")
    var from: String

    @Option(name: .long, help: "Primary destination library folder (or supplied by --preset).")
    var to: String?

    @Option(name: .long, help: "Additional mirror destination folder (repeatable).")
    var archive: [String] = []

    @Option(name: .long, help: "Apply a saved ingest preset by name.")
    var preset: String?

    @Flag(inversion: .prefixedNo, help: "Hash-verify each copy (default on).")
    var verify: Bool?

    @Flag(inversion: .prefixedNo, help: "Eject the card when finished (default off).")
    var eject: Bool?

    @Option(name: .customLong("description"), help: "Description used by the naming templates.")
    var descriptionText: String = ""

    @Option(name: .long, help: "Day-folder name template.")
    var folderTemplate: String?

    @Option(name: .long, help: "File-name stem template.")
    var fileTemplate: String?

    @Option(name: .long, help: "Apply a named folder layout (see `photodrop layouts`). Individual template options override it.")
    var layout: String?

    @Flag(inversion: .prefixedNo, help: "Put a year folder above the day folder (default on).")
    var yearFolder: Bool?

    @Option(name: .long, help: "Executable to run after a clean ingest (the app's post-ingest hook, for headless runs).")
    var postIngestHook: String?

    func run() async throws {
        let cardURL = URL(fileURLWithPath: from, isDirectory: true)

        let loadedPreset: IngestPreset?
        if let preset {
            loadedPreset = IngestPreset.loadAll(from: PresetStore.defaultURL).first { $0.name == preset }
            guard loadedPreset != nil else { CLIOutput.error("No preset named “\(preset)”."); throw ExitCode(2) }
        } else {
            loadedPreset = nil
        }

        guard let primaryPath = (to ?? loadedPreset?.primaryDestination).flatMap({ $0.isEmpty ? nil : $0 }) else {
            CLIOutput.error("A primary destination is required (--to or a preset that defines one).")
            throw ExitCode(2)
        }
        let primaryURL = URL(fileURLWithPath: primaryPath, isDirectory: true)

        // The destination must already exist. `FileCopier.copyAndHash` creates
        // intermediate directories, so a typo'd `--to` silently materialized a
        // whole new library tree and exited 0 with a manifest attesting to it —
        // the photos were "ingested" into a folder nobody would look in again.
        // Creating a library is a deliberate act; make the user do it.
        var primaryIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: primaryURL.path, isDirectory: &primaryIsDirectory),
              primaryIsDirectory.boolValue else {
            CLIOutput.error("Destination “\(CLIOutput.safe(primaryURL.path))” does not exist. Create it first.")
            throw ExitCode(2)
        }

        // Every path here is deduped against the others and against the primary
        // (see ArchiveDestinations) — writing one root twice makes the second
        // pass collide with the first and reports a clean job as a total failure.
        let archiveURLs: [URL]
        if !archive.isEmpty {
            archiveURLs = ArchiveDestinations.mirrors(primary: primaryPath, candidates: archive)
        } else if let preset = loadedPreset {
            // Honour every mirror the preset carries: primary archive + extras.
            archiveURLs = ArchiveDestinations.list(
                primary: primaryPath, archive: preset.archiveDestination,
                extra: preset.extraArchiveDestinations)
        } else {
            archiveURLs = []
        }

        // Precedence, narrowest wins: an explicit template option, then a named
        // layout, then the preset, then the shipped default.
        let namedLayout: FolderLayout?
        if let layout {
            namedLayout = FolderLayout.builtIn.first { $0.name.caseInsensitiveCompare(layout) == .orderedSame }
            guard namedLayout != nil else {
                CLIOutput.error("No layout named “\(CLIOutput.safe(layout))”. Run `photodrop layouts` to list them.")
                throw ExitCode(2)
            }
        } else {
            namedLayout = nil
        }
        let template = NamingTemplate(
            folder: folderTemplate ?? namedLayout?.template.folder ?? loadedPreset?.folderTemplate ?? NamingTemplate.default.folder,
            filename: fileTemplate ?? namedLayout?.template.filename ?? loadedPreset?.fileTemplate ?? NamingTemplate.default.filename,
            yearFolder: yearFolder ?? namedLayout?.template.yearFolder ?? loadedPreset?.yearFolder ?? NamingTemplate.default.yearFolder
        )
        let doVerify = verify ?? loadedPreset?.verifyCopies ?? true

        // Say where a preset is sending the photos.
        //
        // `presets.json` is unsigned data in Application Support, and
        // `IngestPreset.apply` writes its destinations straight into the settings
        // this app treats as trusted. Anyone who can write that file can redirect
        // every future `--preset` run to a path of their choosing, and a headless
        // or launchd invocation would never show it. This is not a gate — writing
        // that file already needs user-level access — but the destinations should
        // never be invisible when they came from a file rather than from argv.
        if loadedPreset != nil, to == nil {
            print("Preset “\(CLIOutput.safe(preset ?? ""))” → \(CLIOutput.safe(primaryURL.path))")
            for mirror in archiveURLs {
                print("  mirror: \(CLIOutput.safe(mirror.path(percentEncoded: false)))")
            }
        }

        // "Couldn't read the card" and "the card has no photos" used to be the
        // same answer — an empty array, printed as *No recognized photos found*
        // and exited 0. A wrapper script reading `$?` then treated a reader that
        // hadn't finished mounting, or a typo'd path, as a completed ingest and
        // released the card. Same rule the verify side already enforces with
        // `.unreadableTarget`.
        let outcome = AssetDiscovery.scanOutcome(root: cardURL)
        guard case let .scanned(bundles, unreadableDirectories, unrecognizedFiles) = outcome else {
            CLIOutput.error("Could not read “\(CLIOutput.safe(cardURL.path))” — it does not exist, is not a folder, or is not readable.")
            throw ExitCode(2)
        }
        if unreadableDirectories > 0 {
            CLIOutput.error("\(unreadableDirectories) folder(s) on the card could not be read; this ingest covers only what was visible. Not ejecting.")
        }
        // Files the walk read and will not copy. Previously dropped in silence,
        // which let a card of stills + clips report a complete ingest of the
        // stills alone and then eject.
        if unrecognizedFiles > 0 {
            CLIOutput.error("\(unrecognizedFiles) file(s) on the card are not a format PhotoDrop ingests "
                          + "and will be left behind. Not ejecting.")
        }
        guard !bundles.isEmpty else {
            print("No recognized photos found on \(cardURL.path).")
            return
        }

        // An incomplete scan never ejects: the card holds the only copy of
        // whatever the walk couldn't see, and ejecting is the one step that puts
        // it out of reach. (`IngestEngine` separately refuses to eject when files
        // failed; this covers what was never planned in the first place.)
        let doEject = (eject ?? loadedPreset?.ejectAfterIngest ?? false)
            && unreadableDirectories == 0 && unrecognizedFiles == 0

        let volumeID = (try? cardURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? cardURL.path
        let cardLabel = (try? cardURL.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? cardURL.lastPathComponent
        let showProgress = isatty(FileHandle.standardError.fileDescriptor) != 0

        // SIGINT / SIGTERM / SIGHUP stop at the next file boundary and still
        // write the manifest — see `GracefulStop`, which `sync` shares.
        let stop = GracefulStop()
        defer { stop.restore() }

        let engine = IngestEngine(
            bundles: bundles, description: descriptionText, primaryRoot: primaryURL,
            archiveRoots: archiveURLs, verify: doVerify, ejectAfter: doEject,
            sourceMountPoint: cardURL.path, sourceVolumeID: volumeID,
            template: template, cardLabel: cardLabel,
            cache: HashCache(storeURL: HashCache.defaultURL),
            indexStoreURL: DestinationIndex.defaultStoreURL,
            isCancelled: { stop.isTripped },
            onProgress: { progress in
                guard showProgress else { return }
                let size = ByteCountFormatter.string(fromByteCount: progress.bytesCopied, countStyle: .file)
                FileHandle.standardError.write(Data("\r  \(progress.completedBundles)/\(progress.totalBundles) bundles · \(size)\u{1B}[K".utf8))
            }
        )
        let result = await engine.run()
        // The copy is over; nothing after this point needs a graceful stop, and
        // everything after it (the hook) needs to remain interruptible.
        stop.restore()
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }

        if result.cancelled { CLIOutput.error("Ingest cancelled — a manifest was written for what already landed.") }
        print(CLIOutput.ingestSummary(result))

        // The app runs the user's post-ingest hook on a clean finish; a headless
        // run silently skipped it. Taken as an explicit option rather than read
        // from the app's defaults, because a command-line tool's UserDefaults
        // domain isn't the app's.
        if let postIngestHook, !postIngestHook.isEmpty,
           !result.halted, !result.cancelled, result.primaryFailures == 0 {
            do {
                try await PostIngestHook.run(scriptPath: postIngestHook, result: result)
            } catch let error as PostIngestHookError {
                CLIOutput.error("Post-ingest hook failed: \(CLIOutput.safe(error.message))")
            }
        }

        if result.halted { throw ExitCode(2) }
        if result.cancelled { throw ExitCode(2) }
        if result.filesFailed > 0 { throw ExitCode(1) }
        // A job that copied everything and could not write its manifest is not a
        // success: the files exist and nothing can ever attest to them. This
        // used to exit 0, so a wrapper script reading `$?` released the card over
        // a library with no integrity record. Exit 1 — "issues found" — rather
        // than 2, because the copy itself completed and was checked.
        if !result.manifestFailures.isEmpty { throw ExitCode(1) }
    }
}

/// Set from a signal-handling dispatch queue, read by the engine's cancellation
/// check on its own task — hence the lock.
private final class InterruptFlag: Sendable {
    private let tripped = OSAllocatedUnfairLock(initialState: false)
    var isTripped: Bool { tripped.withLock { $0 } }
    func trip() { tripped.withLock { $0 = true } }
}

/// Turns SIGINT, SIGTERM and SIGHUP into a request to stop at the next file
/// boundary — for **every** command that writes.
///
/// A termination signal asks the engine to stop at the next file boundary
/// instead of killing the process mid-write. Without this the copy is
/// terminated partway through a file, leaving a partial in the destination with
/// no manifest entry and no checksum xattr — invisible to both verify modes, and
/// on re-ingest its size differs so dedup misses it and the *real* file gets
/// pushed to `…_1`.
///
/// SIGTERM and SIGHUP are handled for exactly the same reason as SIGINT and were
/// missed: closing the terminal window (SIGHUP), `pkill photodrop`, a launchd
/// job hitting its exit timeout, and logging out all default to termination, and
/// none of them run `FileCopier`'s Swift `catch` cleanup. Ctrl-C was the only
/// one of the four anybody tested. Each is ignored at the POSIX level so its
/// dispatch source sees it. A **second** signal exits immediately. Without an
/// escalation path there was none: the handler only re-tripped an
/// already-tripped flag and reprinted the same line, so hammering Ctrl-C during
/// a multi-GB file on a slow reader could not stop the process and the user had
/// to `kill` from another terminal — which then hit the very orphan-file problem
/// the graceful stop exists to prevent. 130 is the conventional "terminated by
/// SIGINT" status.
///
/// **One definition, used by `ingest` and `sync`.** This lived inline in
/// `ingest`, and `sync` — the second command that writes — shipped without it.
/// A Ctrl-C mid-file killed the process with the file half written at the
/// mirror, invisible to the manifest and the xattr stamp; the *next* sync found
/// bytes at that path that did not match its record, reported CONFLICT and,
/// correctly, refused to touch them. One interrupted catch-up made a permanent
/// conflict out of a file that had merely been cut short. The mechanism was
/// forty lines away; the sink was missed. Anything else that writes goes
/// through this.
///
/// `restore()` puts the default dispositions back — not merely cancels the
/// sources — and callers run it as soon as the copy is over, **before** any
/// post-ingest hook. The sources used to be cancelled at scope exit while
/// `SIG_IGN` stayed installed, so signals were swallowed for the rest of the
/// process; with a hook that blocks (on stdin, on a dead mount) that made the
/// CLI un-interruptible — Ctrl-C ignored, SIGTERM ignored. Idempotent, so the
/// `defer` backstop is free.
private final class GracefulStop {
    private let flag = InterruptFlag()
    private var sources: [DispatchSourceSignal] = []
    private let signals: [(number: Int32, label: String)] = [
        (SIGINT, "Interrupted"), (SIGTERM, "Terminating"), (SIGHUP, "Hung up"),
    ]

    /// True once a signal has arrived. Poll it from the engine's `isCancelled`.
    var isTripped: Bool { flag.isTripped }

    init() {
        let flag = self.flag
        for (number, label) in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                if flag.isTripped {
                    FileHandle.standardError.write(Data(
                        "\nStopping now. The file being written is incomplete and is not in the manifest.\n".utf8))
                    // Qualified: `ParsableCommand` has its own `exit(withError:)`.
                    // This runs on a dispatch queue, not in a real signal
                    // handler, so `exit(3)` (with its atexit/flush) is fine.
                    Darwin.exit(130)
                }
                flag.trip()
                FileHandle.standardError.write(Data(
                    "\n\(label) — finishing the current file, then writing the manifest. Press again to stop immediately.\n".utf8))
            }
            source.resume()
            sources.append(source)
        }
    }

    func restore() {
        for source in sources { source.cancel() }
        sources.removeAll()
        for (number, _) in signals { signal(number, SIG_DFL) }
    }

    deinit { restore() }
}

// MARK: - verify

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-verify a library (or a manifest .json) against its recorded checksums."
    )

    @Argument(help: "A library folder, its “PhotoDrop Manifests” folder, or a manifest .json.")
    var target: String

    @Flag(name: .long, help: "Emit a JSON report instead of human-readable text.")
    var json = false

    @Flag(name: .long, help: "Verify by each file's embedded checksum (xattr) instead of the manifest — works on any folder, even reorganized.")
    var xattr = false

    func run() throws {
        let url = URL(fileURLWithPath: target)
        let showProgress = !json && isatty(FileHandle.standardError.fileDescriptor) != 0
        let onProgress: (VerifyProgress) -> Void = { progress in
            guard showProgress else { return }
            FileHandle.standardError.write(Data("\r  verifying \(progress.checked)/\(progress.total)…".utf8))
        }

        let report: VerifyReport?
        if xattr {
            switch VerifyEngine.runXattr(folder: url, onProgress: onProgress) {
            case .report(let r):
                report = r
            case .unreadableTarget:
                if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
                // Exit 2, never 0. A target we could not read is the one case
                // where "no checksummed files found" would be a lie — and a
                // verification tool that exits 0 on a path it never opened turns
                // a typo in a script into a permanent green check.
                CLIOutput.error("Cannot read \(CLIOutput.safe(url.path)) — no such folder, "
                              + "not a folder, or permission denied.")
                throw ExitCode(2)
            case .cancelled:
                report = nil
            }
        } else {
            report = VerifyEngine.run(target: url, onProgress: onProgress)
        }
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }   // clear progress line

        guard let report else {
            CLIOutput.error("Verification was interrupted.")
            throw ExitCode(2)
        }
        guard report.total > 0 else {
            if xattr {
                // The folder was readable and holds nothing stamped. That is only
                // "genuinely not an error" when there was nothing there to stamp.
                // A mirror on exFAT or SMB — where `setxattr` fails and the stamp
                // silently no-ops — is *full of files* and carries no checksums,
                // and this line was reporting it with exit 0. Say what was
                // actually skipped, and refuse to call it a pass.
                if report.unstamped > 0 || report.unreadableDirectories > 0 {
                    CLIOutput.error(CLIOutput.xattrNothingChecked(at: url, report: report))
                    throw ExitCode(1)
                }
                print("No checksummed (xattr) files found under \(CLIOutput.safe(url.path)).")
                return
            }
            CLIOutput.error(CLIOutput.nothingToCheck(at: url, manifestCount: report.manifestCount))
            throw ExitCode(2)
        }

        print(json ? CLIOutput.verifyJSON(report) : CLIOutput.verifyHuman(report))
        if !report.allGood { throw ExitCode(1) }   // 0 = all good, 1 = issues found
    }
}

// MARK: - Output formatting

enum CLIOutput {
    static func error(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Neutralizes filename-derived text so it can't drive the terminal or
    /// reorder the verdict line.
    ///
    /// Filenames come off the card verbatim (`ManifestEntry.name`) and manifest
    /// paths come out of an untrusted JSON, while this CLI writes its progress
    /// line with `\r\u{1B}[K` — so the terminal is honouring escape sequences.
    /// An unescaped `\r` or `\u{1B}[2K` in a path could blank or rewrite the very
    /// summary line that is the tool's entire output, which for a verification
    /// tool means forging its verdict. Everything printed below that can carry
    /// card- or manifest-derived text goes through this.
    ///
    /// The rule itself lives in `SafeText` (Core) so the log, the restore script
    /// and this share one definition — and so it is covered by the test target,
    /// which cannot see `Sources/PhotoDropCLI`.
    static func safe(_ s: String) -> String { SafeText.display(s) }

    /// Why there was nothing to check.
    ///
    /// Distinguishes "no manifest here" from "manifests read, but every entry was
    /// rejected". The second case means the recorded paths escaped the library
    /// root, which is either a corrupt manifest or a crafted one — reporting it
    /// as a plain "no manifest found" would hide exactly the situation the user
    /// most needs to know about.
    static func nothingToCheck(at url: URL, manifestCount: Int) -> String {
        guard manifestCount > 0 else {
            return "No verification manifest found at \(url.path). Run an ingest first, or point at a folder containing a “\(ManifestWriter.folderName)” folder."
        }
        return """
        Read \(manifestCount) manifest\(manifestCount == 1 ? "" : "s") at \(url.path), but none recorded a usable file.
        Entries whose recorded path resolves outside the library root are ignored — a manifest that \
        contains only such entries is either damaged or was not written by PhotoDrop.
        """
    }

    static func healHuman(_ r: HealReport) -> String {
        guard !r.allHealthy else {
            return (["✓ All \(r.total) file\(r.total == 1 ? "" : "s") healthy."] + refusedMirrorNote(r))
                .joined(separator: "\n")
        }
        var lines = ["⚠ \(r.candidates.count) of \(r.total) files damaged/missing — \(r.recoverable.count) recoverable, \(r.unrecoverable.count) unrecoverable:"]
        for c in r.candidates {
            let kind: String
            switch c.kind {
            case .changed:    kind = "CHANGED"
            case .missing:    kind = "MISSING"
            case .conflicted: kind = "CONFLICT"
            }
            lines.append("  \(kind) \(safe(c.relPath))")
            if let from = c.recoverableFrom {
                lines.append("    ↳ recoverable from \(safe(from))")
            } else if c.kind == .conflicted {
                lines.append("    ↳ NOT HEALABLE — two manifests record different checksums for this file;")
                lines.append("      the library cannot vouch for it. Run `photodrop verify` and resolve by hand.")
            } else {
                lines.append("    ↳ UNRECOVERABLE — no healthy mirror copy")
            }
        }
        return (lines + refusedMirrorNote(r)).joined(separator: "\n")
    }

    /// Recorded mirror roots that were not searched, and why. Never silent: "we
    /// didn't look there" is the kind of quiet narrowing that makes a recovery
    /// tool lie by omission, and only the user can say whether the root is theirs.
    /// The paths come from the manifest, so they are untrusted text.
    private static func refusedMirrorNote(_ r: HealReport) -> [String] {
        guard !r.refusedMirrorRoots.isEmpty else { return [] }
        var lines = ["", "Not searched — these recorded mirror roots carry no PhotoDrop manifest,"]
        lines.append("so they may not be destinations you configured:")
        lines += r.refusedMirrorRoots.map { "  \(safe($0))" }
        lines.append("Pass --mirror <path> to search one you recognize.")
        return lines
    }

    static func healJSON(_ r: HealReport) -> String {
        struct CandidateDTO: Encodable { let kind: String; let path: String; let badPath: String; let recoverableFrom: String? }
        struct ReportDTO: Encodable {
            let healthy: Int, total: Int, manifestCount: Int
            let recoverable: Int, unrecoverable: Int, allHealthy: Bool
            let candidates: [CandidateDTO]
            let refusedMirrorRoots: [String]
        }
        let dto = ReportDTO(
            healthy: r.healthy, total: r.total, manifestCount: r.manifestCount,
            recoverable: r.recoverable.count, unrecoverable: r.unrecoverable.count, allHealthy: r.allHealthy,
            candidates: r.candidates.map {
                let kind: String
                switch $0.kind {
                case .changed:    kind = "changed"
                case .missing:    kind = "missing"
                case .conflicted: kind = "conflicted"
                }
                return CandidateDTO(kind: kind, path: $0.relPath,
                                    badPath: $0.badPath, recoverableFrom: $0.recoverableFrom)
            },
            refusedMirrorRoots: r.refusedMirrorRoots
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(dto)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func ingestSummary(_ r: CopyResult) -> String {
        var parts = ["\(r.filesCopied) copied"]
        if r.filesSkipped > 0 { parts.append("\(r.filesSkipped) skipped") }
        if r.filesFailed > 0 { parts.append("\(r.filesFailed) failed") }
        let size = ByteCountFormatter.string(fromByteCount: r.totalBytes, countStyle: .file)
        // "Ingest complete" is a claim about the *card*, not about the files that
        // landed — a cancelled run copied everything it reports and still left
        // the rest behind, so it must not be ticked off as complete.
        let lead: String
        if r.halted {
            lead = "✗ Halted (\(r.haltReason ?? "error")): "
        } else if r.cancelled {
            lead = "⚠ Cancelled — partial ingest: "
        } else if r.primaryFailures > 0 {
            lead = "⚠ Completed with errors: "
        } else if !r.manifestFailures.isEmpty {
            lead = "⚠ Copied, but no manifest was written: "
        } else if !r.failedMirrors.isEmpty {
            lead = "⚠ Library complete, mirror incomplete: "
        } else {
            lead = "✓ Ingest complete: "
        }
        var s = lead + parts.joined(separator: ", ") + " · " + size
        if let manifestURL = r.manifestURL { s += "\n  manifest: \(manifestURL.path)" }
        for root in r.manifestFailures {
            s += "\n  could not write manifest at: \(safe(root))"
        }
        for mirror in r.failedMirrors {
            s += "\n  could not write mirror: \(safe(mirror))"
        }
        if r.wasEjected { s += "\n  card ejected" }
        return s
    }

    /// Why a `--xattr` run checked nothing, when there were files to check.
    static func xattrNothingChecked(at url: URL, report r: VerifyReport) -> String {
        var lines = ["✗ Nothing could be verified under \(safe(url.path))."]
        if r.unstamped > 0 {
            lines.append("  \(r.unstamped) file(s) carry no checksum attribute. Extended attributes are "
                       + "stripped by exFAT/FAT and some network shares and sync tools, so this folder may "
                       + "never have been stampable. Verify it against its manifest instead.")
        }
        if r.unreadableDirectories > 0 {
            lines.append("  \(r.unreadableDirectories) folder(s) could not be read.")
        }
        return lines.joined(separator: "\n")
    }

    static func verifyHuman(_ r: VerifyReport) -> String {
        let files = "\(r.total) file\(r.total == 1 ? "" : "s")"
        let scope = r.manifestCount == 0   // xattr mode doesn't use manifests
            ? files
            : "\(files) across \(r.manifestCount) manifest\(r.manifestCount == 1 ? "" : "s")"
        guard !r.allGood else {
            var ok = "✓ All \(scope) match their recorded checksums."
            // Even a pass says what it did not look at. Without this line a
            // library that lost 9,000 of 10,000 xattrs read as a clean bill of
            // health over the 1,000 that survived.
            if r.unstamped > 0 {
                ok += "\n  \(r.unstamped) file(s) carry no checksum attribute and were not checked."
            }
            ok += unexaminedLines(r)
            return ok
        }
        var headline = "✗ \(r.verified) of \(scope) verified — \(r.changed) changed, \(r.missing) missing, \(r.unreadable) unreadable"
        if r.conflicts > 0 { headline += ", \(r.conflicts) conflicting" }
        var lines = [headline + ":"]
        // Anything the run did not examine is stated in the headline block, not
        // buried: a count of files that were never opened is the difference
        // between a verdict about the library and a verdict about a subset of it.
        if r.unreadableDirectories > 0 {
            lines.append("  \(r.unreadableDirectories) folder(s) could not be read and were not checked.")
        }
        if r.unstamped > 0 {
            lines.append("  \(r.unstamped) file(s) carry no checksum attribute and were not checked.")
        }
        let extra = unexaminedLines(r)
        if !extra.isEmpty { lines.append(contentsOf: extra.split(separator: "\n").map(String.init)) }
        for issue in r.issues {
            let tag: String
            switch issue.kind {
            case .changed:    tag = "CHANGED   "
            case .missing:    tag = "MISSING   "
            case .unreadable: tag = "UNREADABLE"
            case .conflict:   tag = "CONFLICT  "
            }
            lines.append("  \(tag) \(safe(issue.path))")
        }
        if r.conflicts > 0 {
            lines.append("")
            lines.append("CONFLICT means two manifests record different checksums for the same file.")
            lines.append("The library's own records disagree — treat those files as unverified.")
        }
        return lines.joined(separator: "\n")
    }

    /// What a manifest-mode run could not use, and what it knows to be
    /// incomplete. Appended to the pass *and* the failure headline, because both
    /// verdicts are claims about the whole library and both were previously
    /// silent about the entries they dropped.
    private static func unexaminedLines(_ r: VerifyReport) -> String {
        var lines: [String] = []
        if r.undigested > 0 {
            lines.append("  \(r.undigested) manifest entr(y/ies) record no checksum and could not be "
                       + "checked. Older manifests recorded none for duplicate-skipped files.")
        }
        if r.outOfRoot > 0 {
            lines.append("  \(r.outOfRoot) manifest entr(y/ies) name a path outside the library and were "
                       + "refused. A manifest is unauthenticated data; entries that escape its root are "
                       + "never followed.")
        }
        if r.partialManifests > 0 {
            lines.append("  \(r.partialManifests) of \(r.manifestCount) manifest(s) are marked partial — "
                       + "the job that wrote them was cancelled, halted, or lost files, so this library is "
                       + "known to be missing photos the card held. What is here is intact.")
        }
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }

    static func verifyJSON(_ r: VerifyReport) -> String {
        struct IssueDTO: Encodable { let kind: String; let name: String; let path: String }
        struct ReportDTO: Encodable {
            let verified: Int, changed: Int, missing: Int, unreadable: Int, conflicts: Int
            let total: Int, manifestCount: Int, allGood: Bool
            /// What the run could not examine. A consumer that only reads
            /// `allGood` is entitled to assume the verdict covered everything;
            /// these say how much of the target it actually reached.
            let unreadableDirectories: Int, unstamped: Int
            /// Manifest-mode counterparts: entries with no digest, entries that
            /// escaped the library root, and manifests whose job did not finish.
            /// `allGood` stays true for all three — they are context, not
            /// integrity errors — so a consumer that branches only on `allGood`
            /// must read these to know what the verdict covered.
            let undigested: Int, outOfRoot: Int, partialManifests: Int
            let issues: [IssueDTO]
        }
        func kindString(_ k: VerifyIssue.Kind) -> String {
            switch k {
            case .changed: return "changed"
            case .missing: return "missing"
            case .unreadable: return "unreadable"
            case .conflict: return "conflict"
            }
        }
        let dto = ReportDTO(
            verified: r.verified, changed: r.changed, missing: r.missing, unreadable: r.unreadable,
            conflicts: r.conflicts,
            total: r.total, manifestCount: r.manifestCount, allGood: r.allGood,
            unreadableDirectories: r.unreadableDirectories, unstamped: r.unstamped,
            undigested: r.undigested, outOfRoot: r.outOfRoot, partialManifests: r.partialManifests,
            issues: r.issues.map { IssueDTO(kind: kindString($0.kind), name: safe($0.name), path: safe($0.path)) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(dto)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - sync

/// Bring a mirror up to date with an already-verified library.
///
/// The gap this closes: a mirror that wasn't mounted at ingest time had no route
/// back. `heal` is report-only and treats recorded mirrors as recovery *sources*,
/// so it would offer the lagging NAS as a place to restore from; `verify` only
/// reports; and re-running the ingest needs the card, which by then is back in
/// the camera. See `SyncEngine` for why this only ever adds files.
struct Sync: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy anything a mirror is missing from an already-verified library."
    )

    @Argument(help: "The library to mirror from.")
    var library: String

    @Option(name: .long, help: "The mirror to bring up to date. Must already exist.")
    var to: String

    @Flag(inversion: .prefixedNo, help: "Hash-verify each copy (default on).")
    var verify = true

    @Flag(name: .long, help: "Emit a JSON report instead of human-readable text.")
    var json = false

    func run() throws {
        let libraryURL = URL(fileURLWithPath: library, isDirectory: true)
        let mirrorURL = URL(fileURLWithPath: to, isDirectory: true)
        let showProgress = !json && isatty(FileHandle.standardError.fileDescriptor) != 0

        // This command writes, so it stops the way `ingest` stops: at a file
        // boundary, with the mirror's manifest written for what landed. It
        // shipped without this — see `GracefulStop` for what a Ctrl-C did.
        let stop = GracefulStop()
        defer { stop.restore() }

        let outcome: SyncEngine.Outcome
        do {
            outcome = try SyncEngine.run(
                library: libraryURL, mirror: mirrorURL, verify: verify,
                isCancelled: { stop.isTripped },
                onProgress: { progress in
                    guard showProgress else { return }
                    FileHandle.standardError.write(
                        Data("\r  \(progress.checked)/\(progress.total)…".utf8))
                })
        } catch let refusal as SyncEngine.Refusal {
            CLIOutput.error(CLIOutput.safe(refusal.description))
            throw ExitCode(2)
        }
        stop.restore()
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }

        if outcome.cancelled {
            CLIOutput.error("Sync cancelled — the mirror's manifest records what landed, marked partial.")
        }
        print(json ? CLIOutput.syncJSON(outcome, mirror: mirrorURL)
                   : CLIOutput.syncHuman(outcome, mirror: mirrorURL))

        // Same ladder as `ingest`: a cancel is 2 (the mirror was not brought up
        // to date and the tool could not say whether it would have been), an
        // issue is 1, nothing to do is a success.
        if outcome.cancelled { throw ExitCode(2) }
        if !outcome.allGood { throw ExitCode(1) }
    }
}

extension CLIOutput {
    static func syncHuman(_ o: SyncEngine.Outcome, mirror: URL) -> String {
        var lines: [String] = []
        let lead = o.cancelled ? "⚠ Sync cancelled — mirror incomplete: "
                 : o.allGood ? "✓ Mirror up to date: " : "⚠ Mirror synced with issues: "
        var parts = ["\(o.copied) copied"]
        if o.alreadyPresent > 0 { parts.append("\(o.alreadyPresent) already present") }
        if !o.conflicting.isEmpty { parts.append("\(o.conflicting.count) conflicting") }
        if !o.failed.isEmpty { parts.append("\(o.failed.count) failed") }
        if !o.missingAtSource.isEmpty { parts.append("\(o.missingAtSource.count) missing from the library") }
        // The byte count is only meaningful when something moved; `.byteCount`
        // renders 0 as "Zero kB", which reads like a bug.
        lines.append(lead + parts.joined(separator: ", ")
                     + (o.bytesCopied > 0 ? " · " + o.bytesCopied.formatted(.byteCount(style: .file)) : ""))

        for path in o.conflicting {
            lines.append("  CONFLICT  \(safe(path))")
        }
        if !o.conflicting.isEmpty {
            lines.append("  CONFLICT means the mirror already holds a different file at that path.")
            lines.append("  Nothing was overwritten. Resolve them yourself, then run sync again.")
        }
        for path in o.missingAtSource {
            lines.append("  MISSING   \(safe(path))  (recorded in the manifest, absent from the library)")
        }
        for failure in o.failed {
            lines.append("  FAILED    \(safe(failure.path)): \(safe(failure.reason))")
        }
        if let manifestURL = o.manifestURL {
            lines.append("  manifest: \(manifestURL.path)")
        } else if o.copied > 0 || !o.allGood {
            // Only a *failure* to write one is a warning. A no-op sync writes no
            // manifest on purpose — see `SyncEngine`.
            lines.append("  warning: no manifest could be written at the mirror, so it cannot be verified on its own.")
        }
        // Whether `heal` will look here. An ingest records only the roots it
        // wrote, so a mirror brought up to date afterwards is not among the
        // library's own destinations, and `heal <library>` refuses unrecorded
        // roots by design (the mirror gate). Said now, while the user has just
        // made this mirror real, rather than discovered the day it is needed.
        if !o.recordedInLibrary {
            lines.append("  note: `photodrop heal <library>` will not search this mirror on its own — the library's")
            lines.append("        manifests do not record it. Pass --mirror \(safe(mirror.path(percentEncoded: false))) when you run heal.")
        }
        return lines.joined(separator: "\n")
    }

    static func syncJSON(_ o: SyncEngine.Outcome, mirror: URL) -> String {
        struct DTO: Encodable {
            let copied: Int, alreadyPresent: Int, bytesCopied: Int64
            let conflicting: [String], missingAtSource: [String]
            let failed: [String], allGood: Bool, manifest: String?
            /// The run was interrupted; `allGood` says nothing about the items
            /// it never reached. A consumer must read this before trusting it.
            let cancelled: Bool
            /// Whether `heal <library>` will search this mirror without `--mirror`.
            let mirror: String, recordedInLibrary: Bool
        }
        let dto = DTO(
            copied: o.copied, alreadyPresent: o.alreadyPresent, bytesCopied: o.bytesCopied,
            conflicting: o.conflicting.map(safe), missingAtSource: o.missingAtSource.map(safe),
            failed: o.failed.map { safe("\($0.path): \($0.reason)") },
            allGood: o.allGood, manifest: o.manifestURL?.path,
            cancelled: o.cancelled,
            mirror: mirror.path(percentEncoded: false), recordedInLibrary: o.recordedInLibrary)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(dto)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
