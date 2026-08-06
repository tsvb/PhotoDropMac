import Foundation

/// The timestamp that names an ingest's on-disk artifacts.
///
/// One job writes two files that have to pair up by name — the manifest at
/// `<root>/PhotoDrop Manifests/ingest-<stamp>.json` and the log at
/// `~/Library/Logs/PhotoDrop/ingest-<stamp>.log`. The format therefore lives
/// here rather than being spelled out at both call sites, where it had already
/// been duplicated and could drift apart unnoticed.
///
/// **Millisecond precision is load-bearing, not decoration.** `ManifestWriter`
/// writes with `.atomic`, which replaces an existing file, so two ingests that
/// share a stamp mean the second silently destroys the first's record of what it
/// copied and at what digest — and a manifest is the only thing that can prove a
/// file arrived intact. At second resolution that collision is reachable in
/// practice: two small ingests finishing inside the same second overwrite each
/// other, which is exactly what happened while verifying the 0.1.0 → 0.1.1
/// upgrade (three ingests, two manifest files). Sub-second precision closes it,
/// since a job has to do real file I/O and consecutive runs cannot land in the
/// same millisecond.
///
/// Precision alone is not a guarantee, though — two concurrent `photodrop`
/// processes can still start inside the same millisecond — so the name is also
/// *claimed* with `O_EXCL` via `claimUniqueName`. Precision keeps the common
/// case tidy; the claim is what makes overwriting impossible.
enum JobStamp {
    /// Sortable, filename-safe, and locale-independent. The trailing group is
    /// milliseconds, separated with `-` rather than `.` so the stamp can never
    /// be mistaken for a file extension by anything walking the folder.
    ///
    /// The formatter is built per call rather than cached in a `static let`:
    /// `DateFormatter` is not `Sendable`, and this runs at most twice per job.
    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    /// Creates `<directory>/<base>.<ext>`, appending `-2`, `-3`, … until it finds
    /// a name nobody holds. Returns the URL of the (empty) file it just created,
    /// or nil if the directory is unwritable or the attempt limit is reached.
    ///
    /// The caller **owns** the returned name: the file now exists, so any other
    /// process racing for it gets `EEXIST` and moves on. Writing the real content
    /// over it afterwards — including via an atomic replace — is safe.
    ///
    /// `O_EXCL` is the point. Checking `fileExists` first and then writing is a
    /// TOCTOU: two processes both see nothing, both write, and the loser's file
    /// is gone. `open(2)` with `O_CREAT | O_EXCL` makes the test-and-create one
    /// atomic operation the kernel arbitrates, which is the only way to be sure
    /// under concurrency. Timestamp precision cannot substitute for it — it only
    /// makes a collision less likely, never impossible.
    ///
    /// The suffix appears only on an actual collision, so ordinary runs keep
    /// clean, purely chronological filenames.
    static func claimUniqueName(in directory: URL, base: String,
                                pathExtension ext: String, attempts: Int = 100) -> URL? {
        for i in 0..<attempts {
            let candidate = i == 0 ? base : "\(base)-\(i + 1)"
            let url = directory.appendingPathComponent("\(candidate).\(ext)")
            let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            }
            if fd >= 0 {
                close(fd)
                return url
            }
            // Anything other than "taken" is a real failure (unwritable
            // directory, bad path); retrying under a new name won't help.
            if errno != EEXIST { return nil }
        }
        return nil
    }
}
