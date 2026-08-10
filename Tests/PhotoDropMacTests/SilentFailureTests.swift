import XCTest
@testable import PhotoDropMac

/// T4-5 — the `try?` cluster. Each of these reported success by saying nothing,
/// which is worse than an error: the user acts on a belief the app knows to be
/// false.
@MainActor
final class SilentFailureTests: XCTestCase {

    private func freshDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SilentFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A preset saved into an unwritable location appeared in the list, appeared
    /// to persist, and was gone at the next launch. The list is in memory; the
    /// write was `try?`.
    func testAPresetThatCannotBePersistedIsReported() throws {
        let dir = try freshDir()
        // A *file* where the store's parent directory has to be: creating the
        // directory fails, so the write cannot succeed.
        let blocked = dir.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let store = PresetStore(storeURL: blocked.appendingPathComponent("presets.json"))

        store.add(IngestPreset(name: "Wedding", primaryDestination: "/lib", archiveDestination: "",
                               folderTemplate: NamingTemplate.default.folder,
                               fileTemplate: NamingTemplate.default.filename,
                               verifyCopies: true, ejectAfterIngest: false))

        XCTAssertNotNil(store.lastError, "a preset that did not persist must say so")
        XCTAssertEqual(store.presets.count, 1, "the in-memory list still reflects the user's action")
    }

    func testASuccessfulSaveClearsAnyPreviousError() throws {
        let dir = try freshDir()
        let store = PresetStore(storeURL: dir.appendingPathComponent("presets.json"))
        store.add(IngestPreset(name: "Studio", primaryDestination: "/lib", archiveDestination: "",
                               folderTemplate: NamingTemplate.default.folder,
                               fileTemplate: NamingTemplate.default.filename,
                               verifyCopies: true, ejectAfterIngest: false))
        XCTAssertNil(store.lastError)

        // And it really is on disk — the point of the whole exercise.
        let reloaded = PresetStore(storeURL: dir.appendingPathComponent("presets.json"))
        XCTAssertEqual(reloaded.presets.map(\.name), ["Studio"])
    }

    /// Ejecting from the sidebar swallowed both outcomes. Eject is the one
    /// irreversible act in the app: "did it work?" is the whole question, and
    /// `IngestEngine` already logs its own eject failures.
    func testTheEjectFailureMessageNamesTheCard() {
        let message = EjectOutcome.failureMessage(card: "NIKON D850", error: "Volume in use")
        XCTAssertTrue(message.contains("NIKON D850"))
        XCTAssertTrue(message.contains("Volume in use"))
    }

    /// Card labels are card-authored, and this string goes into an alert.
    func testTheEjectFailureMessageNeutralizesTheCardLabel() {
        let message = EjectOutcome.failureMessage(card: "A\u{1B}[2KB", error: "x")
        XCTAssertFalse(message.unicodeScalars.contains("\u{1B}"))
    }
}
