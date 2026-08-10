import Foundation

/// A named destination layout — the folder pattern, the filename pattern, and
/// whether a year level sits above them.
///
/// These are *layout only*: they set how paths are built and say nothing about
/// where to save. The destination stays whatever the user picked, which is how
/// people actually describe this ("choose a folder, then put the files in
/// `YYYY-MM-DD/originalname.jpg` under it"). `IngestPreset` is the other thing
/// and keeps its own job: it captures destinations, verify/eject and templates
/// together, for switching an entire configuration at once.
///
/// Applying one is just a starting point — the templates remain fully editable
/// afterwards, so a layout is a shortcut, never a mode.
struct FolderLayout: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    /// One line, in the user's terms, of what this produces.
    let detail: String
    let template: NamingTemplate

    /// What this layout produces for `context`, relative to the destination
    /// root — rendered through the same code path as a real copy.
    ///
    /// The UI shows this next to each option. Generating it rather than writing
    /// it out by hand is the point: a hard-coded example drifts from the engine
    /// the first time either changes, and it would drift in the one place the
    /// user is deciding which layout to trust with their photos.
    func samplePath(context: TemplateContext = NamingTemplate.sampleContext,
                    fileExtension: String = "DNG") -> String {
        NamingTemplate.relativeSamplePath(folder: template.folder, filename: template.filename,
                                          yearFolder: template.yearFolder,
                                          context: context, fileExtension: fileExtension)
    }

    /// Write this layout into the shared settings.
    ///
    /// One method, used by both the inspector and Settings → Naming: two copies
    /// of "set these three keys" is exactly how two surfaces end up disagreeing
    /// about what a layout means. Mirrors `IngestPreset.apply`, and like it
    /// writes through `UserDefaults` so every `@AppStorage` reader updates.
    func apply(to defaults: UserDefaults = .standard) {
        defaults.set(template.folder, forKey: IngestPreset.Keys.folder)
        defaults.set(template.filename, forKey: IngestPreset.Keys.filename)
        defaults.set(template.yearFolder, forKey: IngestPreset.Keys.yearFolder)
    }

    // MARK: - The built-ins

    /// `{root}/2026-05-28/IMG_0001.jpg` — the date, then the name the camera
    /// gave the file. The layout this feature was asked for.
    static let dateAndOriginalName = FolderLayout(
        name: "Date + original name",
        detail: "One folder per day, files keep the names the camera gave them.",
        template: NamingTemplate(folder: "{yyyy-MM-dd}", filename: "{OriginalStem}", yearFolder: false))

    /// `{root}/2026-05-28/20260528_143022_IMG_0001.jpg` — same folders, but names
    /// that sort chronologically and can't collide between two cameras that both
    /// number from IMG_0001.
    static let dateAndTimestampedName = FolderLayout(
        name: "Date + timestamped name",
        detail: "One folder per day; names lead with the capture time so they sort chronologically and never collide.",
        template: NamingTemplate(folder: "{yyyy-MM-dd}", filename: "{yyyyMMdd_HHmmss}_{OriginalStem}",
                                 yearFolder: false))

    /// `{root}/2026/2026-05-28/IMG_0001.jpg` — the year level kept, for a library
    /// spanning enough years that a flat list of day folders gets unwieldy.
    static let yearDateAndOriginalName = FolderLayout(
        name: "Year / date + original name",
        detail: "A year folder above each day folder — easier to navigate once a library spans several years.",
        template: NamingTemplate(folder: "{yyyy-MM-dd}", filename: "{OriginalStem}", yearFolder: true))

    /// `{root}/2026-05-28_Wedding/IMG_0001.jpg` — folds in the description typed
    /// before the ingest. The `[…]` group drops when there is no description, so
    /// the folder is never left with a trailing underscore.
    static let dateAndDescription = FolderLayout(
        name: "Date + description",
        detail: "Adds the description you type before ingesting to the folder name; omitted when you leave it blank.",
        template: NamingTemplate(folder: "{yyyy-MM-dd}[_{Description}]", filename: "{OriginalStem}",
                                 yearFolder: false))

    static let builtIn: [FolderLayout] = [
        dateAndOriginalName,
        dateAndTimestampedName,
        yearDateAndOriginalName,
        dateAndDescription,
    ]

    /// The layout matching the templates currently in force, if any — so the UI
    /// can show which one is selected without storing a separate "which preset"
    /// key that could disagree with the templates themselves.
    static func matching(_ template: NamingTemplate) -> FolderLayout? {
        builtIn.first { $0.template == template }
    }
}
