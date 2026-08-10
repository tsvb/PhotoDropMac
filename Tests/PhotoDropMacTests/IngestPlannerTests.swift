import XCTest
@testable import PhotoDropMac

/// `IngestPlanner` had **zero test references**, despite owning the state the
/// whole UI reads: the file count beside the Ingest button, the preview tree, and
/// — since the scan-outcome work — `scanWasComplete`, which gates the auto-eject.
///
/// The gating is the part that matters. If a partial or failed scan ever stopped
/// being distinguishable here, the app would go back to ingesting a truncated
/// view of a card and then ejecting it.
@MainActor
final class IngestPlannerTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IngestPlannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
                for case let u as URL in e {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
                }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func drive(at url: URL, label: String = "CARD") -> DetectedDrive {
        DetectedDrive(id: url.path, label: label, mountPoint: url.path, url: url, totalBytes: 0)
    }

    private func write(_ name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 512).write(to: dir.appendingPathComponent(name))
    }

    /// Polls rather than sleeping a fixed interval, and **fails** on timeout —
    /// a skip or a silent give-up here would hide exactly the hang it guards.
    private func waitForScan(_ planner: IngestPlanner, timeout: Double = 5) async throws {
        var ticks = 0
        let limit = Int(timeout / 0.02)
        while planner.isScanning && ticks < limit {
            try await Task.sleep(nanoseconds: 20_000_000)
            ticks += 1
        }
        XCTAssertFalse(planner.isScanning, "the scan never finished")
    }

    func testACompleteScanPlansAndReportsComplete() async throws {
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try write("IMG_0001.JPG", in: card.appendingPathComponent("DCIM", isDirectory: true))
        try write("IMG_0002.JPG", in: card.appendingPathComponent("DCIM", isDirectory: true))

        let planner = IngestPlanner()
        planner.setSource(drive(at: card), description: "", template: .default)
        try await waitForScan(planner)

        XCTAssertEqual(planner.photoCount, 2)
        XCTAssertEqual(planner.totalFiles, 2)
        XCTAssertTrue(planner.scanWasComplete)
        XCTAssertFalse(planner.sourceUnreadable)
        XCTAssertEqual(planner.unreadableDirectories, 0)
    }

    /// An unreadable card is not an empty one — and must not read as complete,
    /// because `scanWasComplete` is what lets the ingest eject.
    func testAnUnreadableCardIsFlaggedAndNotComplete() async throws {
        try XCTSkipIf(getuid() == 0, "root bypasses the permission bits this test relies on")
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try write("IMG_0001.JPG", in: card)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: card.path)

        let planner = IngestPlanner()
        planner.setSource(drive(at: card), description: "", template: .default)
        try await waitForScan(planner)

        XCTAssertTrue(planner.sourceUnreadable)
        XCTAssertFalse(planner.scanWasComplete, "an unreadable card must never authorize an eject")
        XCTAssertEqual(planner.photoCount, 0)
    }

    func testAPartialScanPlansWhatItSawButIsNotComplete() async throws {
        try XCTSkipIf(getuid() == 0, "root bypasses the permission bits this test relies on")
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try write("IMG_0001.JPG", in: card.appendingPathComponent("DCIM100", isDirectory: true))
        let locked = card.appendingPathComponent("DCIM101", isDirectory: true)
        try write("IMG_0002.JPG", in: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let planner = IngestPlanner()
        planner.setSource(drive(at: card), description: "", template: .default)
        try await waitForScan(planner)

        XCTAssertEqual(planner.photoCount, 1, "it plans what it could see")
        XCTAssertGreaterThan(planner.unreadableDirectories, 0, "and says it didn't see everything")
        XCTAssertFalse(planner.scanWasComplete)
    }

    /// Deselecting a card must clear the previous one's state — otherwise a stale
    /// `sourceUnreadable` or file count outlives the card it described.
    func testClearingTheSourceResetsEverything() async throws {
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try write("IMG_0001.JPG", in: card)

        let planner = IngestPlanner()
        planner.setSource(drive(at: card), description: "", template: .default)
        try await waitForScan(planner)
        XCTAssertEqual(planner.photoCount, 1)

        planner.setSource(nil, description: "", template: .default)
        XCTAssertEqual(planner.photoCount, 0)
        XCTAssertEqual(planner.totalFiles, 0)
        XCTAssertFalse(planner.isScanning)
        XCTAssertFalse(planner.sourceUnreadable)
        XCTAssertEqual(planner.unreadableDirectories, 0)
    }

    /// Swapping cards quickly: the second card's result must win. `Task.isCancelled`
    /// is the generation token, and nothing pinned that it works.
    func testASupersededScanCannotOverwriteANewerOne() async throws {
        let tmp = try freshTempDir()
        let first = tmp.appendingPathComponent("first", isDirectory: true)
        let second = tmp.appendingPathComponent("second", isDirectory: true)
        for i in 1...3 { try write("IMG_000\(i).JPG", in: first) }
        try write("ONLY_0001.JPG", in: second)

        let planner = IngestPlanner()
        planner.setSource(drive(at: first), description: "", template: .default)
        planner.setSource(drive(at: second, label: "SECOND"), description: "", template: .default)
        try await waitForScan(planner)
        // Give any straggler continuation from the first scan time to land.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(planner.photoCount, 1, "the first card's 3 photos came back and won")
        let names = planner.yearGroups
            .flatMap { $0.folders.flatMap(\.bundles) }
            .map(\.primary.url.lastPathComponent)
        XCTAssertEqual(names, ["ONLY_0001.JPG"])
    }

    /// Re-planning on a description change must not re-scan the card, and must
    /// reach the destination folder names the copy engine will use.
    func testDescriptionChangeReplansWithoutRescanning() async throws {
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try write("IMG_0001.JPG", in: card)

        let planner = IngestPlanner()
        planner.setSource(drive(at: card), description: "", template: .default)
        try await waitForScan(planner)

        // Replanning is debounced — it used to run synchronously on the main
        // actor for every keystroke, rebuilding the whole plan per character.
        // `replanNow()` is what `startIngest` calls, so the plan can never be one
        // debounce interval stale when the copy begins.
        planner.updateDescription("Beach Day")
        planner.replanNow()
        XCTAssertFalse(planner.isScanning, "changing the description must not re-read the card")
        let folder = planner.yearGroups.first?.folders.first?.dayName
        XCTAssertEqual(folder?.hasSuffix("_Beach_Day"), true, "got \(folder ?? "nil")")
    }
}
