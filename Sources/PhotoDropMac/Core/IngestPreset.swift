import Foundation
import Observation

/// A saved bundle of ingest settings — destinations, naming templates, and the
/// verify/eject options — so a photographer can switch the whole configuration
/// in one click ("Wedding", "Personal", "Drone"). Applying a preset writes the
/// shared `@AppStorage` keys, so every view that reads them updates; capturing
/// reads those same keys back.
struct IngestPreset: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var primaryDestination: String
    var archiveDestination: String
    /// Newline-separated additional mirror destinations (beyond the primary
    /// archive). Same format as the `extraArchiveDestinations` default.
    var extraArchiveDestinations: String
    var folderTemplate: String
    var fileTemplate: String
    var verifyCopies: Bool
    var ejectAfterIngest: Bool
    /// Whether a `{yyyy}` level sits above the day folder — see
    /// `NamingTemplate.yearFolder`.
    var yearFolder: Bool

    init(id: UUID = UUID(), name: String, primaryDestination: String, archiveDestination: String,
         extraArchiveDestinations: String = "", folderTemplate: String, fileTemplate: String,
         verifyCopies: Bool, ejectAfterIngest: Bool, yearFolder: Bool = true) {
        self.id = id
        self.name = name
        self.primaryDestination = primaryDestination
        self.archiveDestination = archiveDestination
        self.extraArchiveDestinations = extraArchiveDestinations
        self.folderTemplate = folderTemplate
        self.fileTemplate = fileTemplate
        self.verifyCopies = verifyCopies
        self.ejectAfterIngest = ejectAfterIngest
        self.yearFolder = yearFolder
    }

    // Decode tolerantly: presets saved before mirror destinations existed have
    // no `extraArchiveDestinations` key — treat that as "no extra mirrors"
    // rather than failing the whole decode (which would drop every saved preset).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        primaryDestination = try c.decode(String.self, forKey: .primaryDestination)
        archiveDestination = try c.decode(String.self, forKey: .archiveDestination)
        extraArchiveDestinations = try c.decodeIfPresent(String.self, forKey: .extraArchiveDestinations) ?? ""
        folderTemplate = try c.decode(String.self, forKey: .folderTemplate)
        fileTemplate = try c.decode(String.self, forKey: .fileTemplate)
        verifyCopies = try c.decode(Bool.self, forKey: .verifyCopies)
        ejectAfterIngest = try c.decode(Bool.self, forKey: .ejectAfterIngest)
        // Presets saved before the year level was optional describe a layout
        // that always had one. Defaulting to `true` keeps such a preset pointing
        // at the same folders it always did; defaulting to `false` would quietly
        // restructure someone's library the next time they applied it.
        yearFolder = try c.decodeIfPresent(Bool.self, forKey: .yearFolder) ?? true
    }

    // The `@AppStorage` keys a preset mirrors (must match the declarations in
    // MainView / InspectorPane / SettingsView).
    enum Keys {
        static let primary = "photodrop.primaryDestination"
        static let archive = "photodrop.archiveDestination"
        static let extraArchives = ArchiveDestinations.extraDefaultsKey
        static let folder = "photodrop.template.folder"
        static let filename = "photodrop.template.filename"
        static let verify = "photodrop.verifyCopies"
        static let eject = "photodrop.ejectAfterIngest"
        static let yearFolder = "photodrop.template.yearFolder"
    }

    /// Snapshot the current settings into a named preset, honouring the same
    /// defaults the `@AppStorage` declarations use when a key is absent.
    static func capture(name: String, from defaults: UserDefaults = .standard) -> IngestPreset {
        IngestPreset(
            name: name,
            primaryDestination: defaults.string(forKey: Keys.primary) ?? "",
            archiveDestination: defaults.string(forKey: Keys.archive) ?? "",
            extraArchiveDestinations: defaults.string(forKey: Keys.extraArchives) ?? "",
            folderTemplate: defaults.string(forKey: Keys.folder) ?? NamingTemplate.default.folder,
            fileTemplate: defaults.string(forKey: Keys.filename) ?? NamingTemplate.default.filename,
            verifyCopies: defaults.object(forKey: Keys.verify) as? Bool ?? true,
            ejectAfterIngest: defaults.object(forKey: Keys.eject) as? Bool ?? false,
            yearFolder: defaults.object(forKey: Keys.yearFolder) as? Bool ?? true
        )
    }

    /// Decode the saved presets at `url` (nonisolated, so the CLI can read them
    /// without the `@MainActor` `PresetStore`). Returns [] if absent/unreadable.
    static func loadAll(from url: URL) -> [IngestPreset] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([IngestPreset].self, from: data) else { return [] }
        return decoded
    }

    /// Write this preset's values into the shared settings.
    func apply(to defaults: UserDefaults = .standard) {
        defaults.set(primaryDestination, forKey: Keys.primary)
        defaults.set(archiveDestination, forKey: Keys.archive)
        defaults.set(extraArchiveDestinations, forKey: Keys.extraArchives)
        defaults.set(folderTemplate, forKey: Keys.folder)
        defaults.set(fileTemplate, forKey: Keys.filename)
        defaults.set(verifyCopies, forKey: Keys.verify)
        defaults.set(ejectAfterIngest, forKey: Keys.eject)
        defaults.set(yearFolder, forKey: Keys.yearFolder)
    }
}

/// Persists the list of ingest presets as JSON in Application Support, and
/// surfaces it as observable UI state.
@MainActor
@Observable
final class PresetStore {
    private(set) var presets: [IngestPreset] = []
    /// Why the last save didn't land, or nil.
    ///
    /// The write was a `try?`, so a preset saved into an unwritable location
    /// appeared in the list, appeared to persist, and was gone at the next
    /// launch — the list is in memory, the file never happened. Saying nothing
    /// is worse than an error here: the user goes on believing the preset
    /// exists.
    private(set) var lastError: String?
    @ObservationIgnored private let storeURL: URL

    init(storeURL: URL = PresetStore.defaultURL) {
        self.storeURL = storeURL
        load()
    }

    func add(_ preset: IngestPreset) {
        presets.append(preset)
        save()
    }

    func delete(_ preset: IngestPreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    func load() {
        presets = IngestPreset.loadAll(from: storeURL)
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(presets)
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storeURL, options: [.atomic])
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearError() { lastError = nil }

    nonisolated static var defaultURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        return base.appendingPathComponent("PhotoDropMac", isDirectory: true)
            .appendingPathComponent("presets.json")
    }
}
