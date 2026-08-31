import Foundation

struct ScannedPhoto: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let size: Int64
    let dateTaken: Date
    let dateSource: DateSource
    /// Camera identity from EXIF; empty when the camera didn't record it.
    /// Feeds the `{CameraModel}` / `{BodySerial}` naming tokens, which are what
    /// make a two-body shoot's colliding filenames tellable apart — see
    /// `TemplateContext.cameraModel`.
    let cameraModel: String
    let bodySerial: String

    enum DateSource: Sendable {
        case exif
        case fileModification
    }

    init(id: URL, url: URL, size: Int64, dateTaken: Date, dateSource: DateSource,
         cameraModel: String = "", bodySerial: String = "") {
        self.id = id
        self.url = url
        self.size = size
        self.dateTaken = dateTaken
        self.dateSource = dateSource
        self.cameraModel = cameraModel
        self.bodySerial = bodySerial
    }
}

// RAW extensions PhotoDrop treats as first-class primaries. A fixed set —
// extend it deliberately rather than inferring RAW-ness from a file's bytes.
private let rawExtensions: Set<String> = [
    "dng", "raf", "arw", "cr2", "cr3", "nef", "nrw", "orf", "rw2",
    "pef", "srw", "3fr", "rwl", "x3f", "erf", "mrw", "mef",
    "iiq", "raw", "sr2", "srf", "dcr", "kdc", "mos",
]

// Camera-written non-RAW stills. Each is either a companion (when a same-stem
// RAW lives in the same directory) or a primary bundle of its own.
//
// **HEIF belongs here, not in a future "maybe".** `heic` is what every iPhone
// since the 7 writes by default, `hif` is Canon's R-series HEIF and Sony's
// equivalent, and all three were dropped by the extension filter below with no
// tally — so an iPhone card or an R5 shooting HEIF+RAW scanned "clean", ingested
// nothing (or only the RAW), reported ✓ and ejected. ImageIO reads their EXIF
// and embedded previews with no change to `ExifReader` or `ThumbnailLoader`.
private let jpegExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "hif"]

// Video written by stills cameras, action cams and phones. Treated exactly like
// a standalone still: a primary in its own bundle, taking the same sidecar
// companions (an `.xmp` beside a clip is as real as one beside a RAW).
//
// These were absent entirely, which was the single largest correctness gap in
// the app: the enumerator dropped them with no counter, so a hybrid shooter's
// card — 400 stills, 60 clips — planned 400 bundles, passed the `filesFailed ==
// 0` eject gate, wrote a manifest attesting to completeness, and ejected the
// only copy of the clips. Capture dates come from `ExifReader`, which falls back
// to AVFoundation's creation metadata for these.
//
// Deliberately *not* here: the multi-file clip containers (spanned MXF, BRAW and
// R3D folders, `.insv` pairs), which are directory-shaped and would need a
// different atomic unit than `AssetBundle`. They are counted as unrecognized
// rather than half-copied, which is the honest answer until that unit exists.
private let videoExtensions: Set<String> = [
    "mov", "mp4", "m4v", "avi", "mts", "m2ts", "3gp", "mpg", "mpeg", "wmv", "mkv",
]

// Recognised sidecar extensions. `.wav` only counts when it shares its
// stem with a primary — it's treated as a camera audio note.
private let sidecarExtensions: Set<String> = ["dop", "xmp", "pp3", "wav"]

/// Files the walk deliberately passes over without counting them as unexamined.
///
/// The unrecognized tally exists to tell the user "this card holds things I did
/// not take", so it must not cry wolf about filesystem and camera bookkeeping
/// that nobody wants ingested: volume indexes, trashes, camera settings and
/// print-order files are noise, not photos.
private let ignorableExtensions: Set<String> = [
    "ds_store", "spotlight-v100", "fseventsd", "trashes", "ctg", "mir", "sea",
    "ind", "inp", "bin", "dat", "log", "tmp", "thm", "lrv", "lrf", "xml", "ini",
    "txt", "url", "htm", "html", "plist", "db", "modd", "moff", "sav",
]
private let ignorableNames: Set<String> = [
    ".ds_store", "misc", "avin", "clpinf", "index.bdm", "moviobj.bdm",
]

// Accepted primary extensions (RAW + JPEG). Anything else is ignored at
// the enumeration stage.
private let primaryExtensions: Set<String> = rawExtensions.union(jpegExtensions).union(videoExtensions)

// Every extension the enumerator needs to surface. Filtering by this
// set up front keeps scratch files (`.tmp`, `.ctg`, etc.) out of the
// in-memory sibling list.
private let recognisedExtensions: Set<String> = primaryExtensions.union(sidecarExtensions)

// One enumerator row after it's been classified. We hold these per
// directory so the two-pass algorithm can run over a single group's
// worth of siblings at a time.
private struct FileEntry {
    let url: URL
    let size: Int64
    let modDate: Date
    let name: String
    let stem: String
    let ext: String
}

/// Tally shared with the enumerator's error handler. A class (not a captured
/// `var`) because the handler is escaping; locked because `FileManager` gives no
/// guarantee about which thread it calls it on.
private final class UnreadableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// What a scan found — or why it found nothing.
///
/// `scan` used to answer `[]` for a card that does not exist, is not mounted yet,
/// or cannot be read, which is the same answer it gives for a card with no
/// photos. The CLI printed *No recognized photos found* and exited **0**, so a
/// nightly wrapper reading `$?` treated an unmounted reader — or a typo'd
/// `/Volumes/CRAD` — as a successful ingest and released the card. This is the
/// same distinction `XattrOutcome` exists to make on the verify side: "couldn't
/// read the target" must never be reported as "nothing there".
///
/// `unreadableDirectories` carries the partial-failure case the enumerator used
/// to swallow silently: a card yanked (or a directory returning EIO) *during*
/// enumeration simply yielded fewer bundles, so a 500-photo card could plan 137
/// files, report "✓ Ingest complete", and write a manifest attesting to the 137.
enum ScanOutcome: Sendable {
    case unreadableSource
    /// - Parameters:
    ///   - unreadableDirectories: directories the walk could not open.
    ///   - unrecognizedFiles: regular files the walk *could* read and chose not
    ///     to ingest because their extension is not a recognized primary or
    ///     sidecar — camera bookkeeping excluded. See `ignorableExtensions`.
    case scanned(bundles: [AssetBundle], unreadableDirectories: Int, unrecognizedFiles: Int)

    var bundles: [AssetBundle] {
        if case let .scanned(bundles, _, _) = self { return bundles }
        return []
    }
    var unreadableDirectories: Int {
        if case let .scanned(_, unreadable, _) = self { return unreadable }
        return 0
    }
    /// Files on the card this ingest will not copy.
    ///
    /// Kept distinct from `unreadableDirectories` because the remedy differs: an
    /// unreadable directory is a fault to retry, while an unrecognized file is a
    /// deliberate limit of the app that the user has to decide about. Both,
    /// though, make `isComplete` false — the card was not fully taken, and no
    /// caller may eject on the strength of a partial one.
    var unrecognizedFiles: Int {
        if case let .scanned(_, _, unrecognized) = self { return unrecognized }
        return 0
    }
    /// Everything on the card was read **and** everything readable was ingestable.
    ///
    /// The unrecognized count joined this deliberately. Ejecting is the app's own
    /// "this card is finished" gesture and the next thing that happens to a
    /// finished card is a format; saying it over a card still holding 60 clips is
    /// the worst outcome this app can produce.
    var isComplete: Bool {
        if case let .scanned(_, unreadable, unrecognized) = self {
            return unreadable == 0 && unrecognized == 0
        }
        return false
    }
}

enum AssetDiscovery {
    /// Bundles only, for the many callers that don't distinguish the failure
    /// modes. Prefer `scanOutcome` anywhere the answer drives an exit code, an
    /// eject, or a claim of completeness.
    static func scan(root: URL) -> [AssetBundle] {
        scanOutcome(root: root).bundles
    }

    // Two-pass discovery:
    //   1. RAW primaries and their same-directory companions.
    //   2. Standalone JPEGs — JPEGs not already claimed as a JpegPair
    //      companion by a RAW in the same directory.
    // Orphan sidecars (a .dop with no primary) are silently dropped.
    static func scanOutcome(root: URL) -> ScanOutcome {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isReadableFile(atPath: root.path) else {
            return .unreadableSource
        }

        // Count directories the walk could not open instead of dropping the
        // error. Without a handler the enumerator skips them silently and the
        // scan just comes back short — indistinguishable from a smaller card.
        let unreadable = UnreadableCounter()
        let unrecognized = UnreadableCounter()
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in unreadable.increment(); return true }
        ) else {
            return .unreadableSource
        }

        // All files that could matter (primary or sidecar), grouped by
        // their parent directory. Same-directory grouping is how the
        // same-directory rule is enforced: we only ever classify
        // siblings inside a single group.
        var byDirectory: [URL: [FileEntry]] = [:]

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // Load-bearing security check, not just a "skip directories" filter.
            // `isRegularFile` has lstat semantics — a symlink reports false — so
            // this is what stops a card from pointing at files outside itself.
            // Without it, a card containing `DCIM/ETC -> /etc` (or a link to
            // ~/.ssh) would have its *targets* read, hashed, and copied into the
            // library. `FileManager.enumerator` separately declines to descend
            // into symlinked directories. Covered by
            // AssetDiscoveryTests.testSymlinksAreNeverIngested.
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard recognisedExtensions.contains(ext) else {
                // **Count what we are leaving behind.** This filter used to
                // `continue` in silence, which made "the card holds 60 clips I
                // cannot ingest" indistinguishable from "the card holds nothing
                // else" — the exact collapse `ScanOutcome` was created to
                // prevent, at the one sink nobody had applied it to. The count
                // suppresses the auto-eject and is stated in the UI and the CLI,
                // so the user decides rather than discovering it after a format.
                let name = url.lastPathComponent.lowercased()
                if !ignorableExtensions.contains(ext), !ignorableNames.contains(name),
                   !name.hasPrefix(".") {
                    unrecognized.increment()
                }
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            let modDate = values.contentModificationDate ?? Date()
            let name = url.lastPathComponent
            let stem = url.deletingPathExtension().lastPathComponent
            let parent = url.deletingLastPathComponent()
            let entry = FileEntry(url: url, size: size, modDate: modDate, name: name, stem: stem, ext: ext)
            byDirectory[parent, default: []].append(entry)
        }

        var bundles: [AssetBundle] = []
        var consumed: Set<URL> = []

        // Stable directory order keeps the output deterministic even if
        // the enumerator visits directories in filesystem order.
        let sortedDirs = byDirectory.keys.sorted { $0.path < $1.path }
        for dir in sortedDirs {
            // Sort the siblings too, for the same reason the directories are
            // sorted. It stopped being cosmetic once `claimed` made a sidecar
            // belong to the *first* matching primary: with two RAWs of the same
            // stem (a CR2 and its converted DNG), enumerator order decided which
            // one got the .xmp, so the same card could produce different bundles
            // on different runs.
            guard let siblings = byDirectory[dir]?.sorted(by: { $0.name < $1.name }) else { continue }

            // Pass 1: RAW primaries.
            for file in siblings where rawExtensions.contains(file.ext) {
                if consumed.contains(file.url) { continue }
                let bundle = buildBundle(primary: file, siblings: siblings, claimed: consumed)
                consumed.insert(file.url)
                for c in bundle.companions { consumed.insert(c.url) }
                bundles.append(bundle)
            }

            // Pass 2: standalone stills and video (those not consumed as a
            // JpegPair companion during pass 1). Video is never a companion —
            // a clip beside a RAW of the same stem is its own shot, not the
            // RAW's pair — so it can only ever appear here.
            for file in siblings where jpegExtensions.contains(file.ext) || videoExtensions.contains(file.ext) {
                if consumed.contains(file.url) { continue }
                let bundle = buildBundle(primary: file, siblings: siblings, claimed: consumed)
                consumed.insert(file.url)
                for c in bundle.companions { consumed.insert(c.url) }
                bundles.append(bundle)
            }
        }

        return .scanned(bundles: bundles,
                        unreadableDirectories: unreadable.value,
                        unrecognizedFiles: unrecognized.value)
    }

    // Build a bundle for `primary`, pulling every sibling that classifies as a
    // companion and is not already claimed. `siblings` is already scoped to the
    // primary's own directory.
    //
    // `claimed` is honoured here, not just by the primary loop: a companion can
    // legitimately match two primaries, and before this it was attached to both.
    // The everyday case is DNG Converter output — `IMG_1234.CR2`, `IMG_1234.DNG`
    // and `IMG_1234.xmp` side by side, where the two RAWs are each other's
    // primaries and neither is the other's companion. The xmp landed in both
    // bundles, so bundle 2 collided with bundle 1 on the sidecar's destination
    // and got pushed to `_1` even though nothing about the DNG collided, and the
    // same sidecar was copied, hashed and manifested twice under two names.
    // First primary wins, which is the rule the primary loop already used.
    private static func buildBundle(
        primary: FileEntry,
        siblings: [FileEntry],
        claimed: Set<URL>
    ) -> AssetBundle {
        let photo = makeScannedPhoto(from: primary)

        var companions: [CompanionFile] = []
        for sibling in siblings {
            if sibling.url == primary.url { continue }
            if claimed.contains(sibling.url) { continue }
            guard let kind = classifyCompanion(
                neighborStem: sibling.stem,
                neighborExt: sibling.ext,
                primaryStem: primary.stem,
                primaryName: primary.name
            ) else { continue }
            companions.append(CompanionFile(url: sibling.url, size: sibling.size, kind: kind))
        }

        return AssetBundle(primary: photo, companions: companions)
    }

    // Decide whether `neighbor` is a companion of the primary. Two
    // shapes are accepted:
    //
    //   A. `<primaryName>.<ext>` — neighbour starts with the primary's
    //      full filename and appends a sidecar extension. Covers the
    //      Adobe-style `IMG_1234.DNG.xmp` and the DxO `IMG_1234.DNG.dop`
    //      variants. Sidecar extensions only.
    //
    //   B. `<primaryStem>.<ext>` — neighbour shares the primary's stem
    //      but has a different extension. Covers the short-form xmp
    //      (`IMG_1234.xmp`), JPEG pairs (`IMG_1234.JPG`), and camera
    //      audio notes (`IMG_1234.WAV`). Sidecar or JPEG extensions.
    //
    // All comparisons are case-insensitive so `.DNG` and `.dng` behave
    // identically.
    //
    // Both shapes match the neighbour's **stem exactly**, never by prefix.
    // `hasPrefix(primaryStem + ".")` also accepted `IMG_1234.v2.xmp` beside
    // `IMG_1234.CR2` as a short-form sidecar — and `CopyPlan` renames a
    // short-form sidecar to `{newStem}.xmp`, byte-identical to what the real
    // `IMG_1234.xmp` gets, so the two planned onto one path. (Prefix matching
    // also swept in anything else a camera or editor happened to name with the
    // primary's stem plus a suffix.)
    private static func classifyCompanion(
        neighborStem: String,
        neighborExt: String,
        primaryStem: String,
        primaryName: String
    ) -> CompanionKind? {
        let stem = neighborStem.lowercased()

        // Case A — <primaryName>.<sidecarExt>, i.e. the stem *is* the primary's
        // whole filename (IMG_1234.DNG.xmp).
        if stem == primaryName.lowercased(), sidecarExtensions.contains(neighborExt) {
            return kind(forExtension: neighborExt)
        }

        // Case B — <primaryStem>.<ext>, where ext is sidecar or jpeg.
        if stem == primaryStem.lowercased(),
           sidecarExtensions.contains(neighborExt) || jpegExtensions.contains(neighborExt)
        {
            return kind(forExtension: neighborExt)
        }

        return nil
    }

    private static func kind(forExtension ext: String) -> CompanionKind? {
        switch ext {
        case "dop": return .dop
        case "xmp": return .xmp
        case "pp3": return .pp3
        case "jpg", "jpeg": return .jpegPair
        case "wav": return .audioNote
        default: return nil
        }
    }

    private static func makeScannedPhoto(from file: FileEntry) -> ScannedPhoto {
        let date: Date
        let source: ScannedPhoto.DateSource
        if let exifDate = ExifReader.dateTaken(for: file.url) {
            date = exifDate
            source = .exif
        } else {
            date = file.modDate
            source = .fileModification
        }
        let camera = ExifReader.cameraInfo(for: file.url)
        return ScannedPhoto(
            id: file.url,
            url: file.url,
            size: file.size,
            dateTaken: date,
            dateSource: source,
            cameraModel: camera.model,
            bodySerial: camera.serial
        )
    }
}
