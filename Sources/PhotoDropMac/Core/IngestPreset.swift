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
    var folderTemplate: String
    var fileTemplate: String
    var verifyCopies: Bool
    var ejectAfterIngest: Bool

    init(id: UUID = UUID(), name: String, primaryDestination: String, archiveDestination: String,
         folderTemplate: String, fileTemplate: String, verifyCopies: Bool, ejectAfterIngest: Bool) {
        self.id = id
        self.name = name
        self.primaryDestination = primaryDestination
        self.archiveDestination = archiveDestination
        self.folderTemplate = folderTemplate
        self.fileTemplate = fileTemplate
        self.verifyCopies = verifyCopies
        self.ejectAfterIngest = ejectAfterIngest
    }

    // The `@AppStorage` keys a preset mirrors (must match the declarations in
    // MainView / InspectorPane / SettingsView).
    enum Keys {
        static let primary = "photodrop.primaryDestination"
        static let archive = "photodrop.archiveDestination"
        static let folder = "photodrop.template.folder"
        static let filename = "photodrop.template.filename"
        static let verify = "photodrop.verifyCopies"
        static let eject = "photodrop.ejectAfterIngest"
    }

    /// Snapshot the current settings into a named preset, honouring the same
    /// defaults the `@AppStorage` declarations use when a key is absent.
    static func capture(name: String, from defaults: UserDefaults = .standard) -> IngestPreset {
        IngestPreset(
            name: name,
            primaryDestination: defaults.string(forKey: Keys.primary) ?? "",
            archiveDestination: defaults.string(forKey: Keys.archive) ?? "",
            folderTemplate: defaults.string(forKey: Keys.folder) ?? NamingTemplate.default.folder,
            fileTemplate: defaults.string(forKey: Keys.filename) ?? NamingTemplate.default.filename,
            verifyCopies: defaults.object(forKey: Keys.verify) as? Bool ?? true,
            ejectAfterIngest: defaults.object(forKey: Keys.eject) as? Bool ?? false
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
        defaults.set(folderTemplate, forKey: Keys.folder)
        defaults.set(fileTemplate, forKey: Keys.filename)
        defaults.set(verifyCopies, forKey: Keys.verify)
        defaults.set(ejectAfterIngest, forKey: Keys.eject)
    }
}

/// Persists the list of ingest presets as JSON in Application Support, and
/// surfaces it as observable UI state.
@MainActor
@Observable
final class PresetStore {
    private(set) var presets: [IngestPreset] = []
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
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: [.atomic])
    }

    nonisolated static var defaultURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        return base.appendingPathComponent("PhotoDropMac", isDirectory: true)
            .appendingPathComponent("presets.json")
    }
}
