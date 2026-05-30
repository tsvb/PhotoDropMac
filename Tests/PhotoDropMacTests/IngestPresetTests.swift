import XCTest
@testable import PhotoDropMac

/// Ingest presets: capture/apply against the shared settings keys, JSON
/// round-trip, and `PresetStore` add/delete/persist. UserDefaults access is
/// isolated to a throwaway suite so the real preferences are untouched.
final class IngestPresetTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let name = "PhotoDropMacPresetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacPresetStore-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("presets.json")
    }

    private func sample(_ name: String = "Wedding") -> IngestPreset {
        IngestPreset(name: name, primaryDestination: "/lib", archiveDestination: "/nas",
                     folderTemplate: "{MM}/{yyyy-MM-dd}", fileTemplate: "{yyyyMMdd_HHmmss}_{OriginalStem}",
                     verifyCopies: true, ejectAfterIngest: true)
    }

    func testCodableRoundTrip() throws {
        let preset = sample()
        let data = try JSONEncoder().encode(preset)
        let back = try JSONDecoder().decode(IngestPreset.self, from: data)
        XCTAssertEqual(back, preset)
    }

    func testCaptureReadsCurrentSettings() {
        let defaults = isolatedDefaults()
        defaults.set("/photos", forKey: IngestPreset.Keys.primary)
        defaults.set("{yyyy}", forKey: IngestPreset.Keys.folder)
        defaults.set(false, forKey: IngestPreset.Keys.verify)

        let preset = IngestPreset.capture(name: "X", from: defaults)
        XCTAssertEqual(preset.primaryDestination, "/photos")
        XCTAssertEqual(preset.folderTemplate, "{yyyy}")
        XCTAssertFalse(preset.verifyCopies)
    }

    func testCaptureUsesDefaultsWhenKeysAbsent() {
        let preset = IngestPreset.capture(name: "X", from: isolatedDefaults())
        XCTAssertEqual(preset.primaryDestination, "")
        XCTAssertEqual(preset.folderTemplate, NamingTemplate.default.folder)
        XCTAssertEqual(preset.fileTemplate, NamingTemplate.default.filename)
        XCTAssertTrue(preset.verifyCopies)        // default on
        XCTAssertFalse(preset.ejectAfterIngest)   // default off
    }

    func testApplyThenCaptureRoundTrips() {
        let defaults = isolatedDefaults()
        let original = sample("Drone")
        original.apply(to: defaults)
        let captured = IngestPreset.capture(name: "Drone", from: defaults)
        // `capture` mints a fresh id by design, so compare the settings fields.
        XCTAssertEqual(captured.name, original.name)
        XCTAssertEqual(captured.primaryDestination, original.primaryDestination)
        XCTAssertEqual(captured.archiveDestination, original.archiveDestination)
        XCTAssertEqual(captured.folderTemplate, original.folderTemplate)
        XCTAssertEqual(captured.fileTemplate, original.fileTemplate)
        XCTAssertEqual(captured.verifyCopies, original.verifyCopies)
        XCTAssertEqual(captured.ejectAfterIngest, original.ejectAfterIngest)
    }

    @MainActor
    func testStoreAddDeleteAndPersist() {
        let url = tempStoreURL()
        let store = PresetStore(storeURL: url)
        XCTAssertTrue(store.presets.isEmpty)

        let a = sample("A"), b = sample("B")
        store.add(a)
        store.add(b)
        store.delete(a)
        XCTAssertEqual(store.presets.map(\.name), ["B"])

        // A fresh store reading the same file sees the persisted state.
        let reloaded = PresetStore(storeURL: url)
        XCTAssertEqual(reloaded.presets.map(\.name), ["B"])
    }
}
