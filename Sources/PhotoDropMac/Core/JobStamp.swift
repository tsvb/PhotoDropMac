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
/// Residual: two *concurrent* `photodrop ingest` processes could still start
/// within a millisecond of each other. Nothing in the app can do that (a single
/// `Copier` runs at a time), and it would require deliberately racing two CLI
/// invocations at the same primary destination.
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
}
