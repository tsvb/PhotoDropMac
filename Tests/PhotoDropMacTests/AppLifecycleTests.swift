import XCTest
@testable import PhotoDropMac

/// T4-2 and T4-4 — what happens to a job when the app goes away, and the
/// card-arrival trigger that never fired.
@MainActor
final class AppLifecycleTests: XCTestCase {

    private func freshDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func card(_ dir: URL, files: Int) throws -> YearGroup {
        let cardDir = dir.appendingPathComponent("card", isDirectory: true)
        try FileManager.default.createDirectory(at: cardDir, withIntermediateDirectories: true)
        var bundles: [AssetBundle] = []
        for i in 1...files {
            let url = cardDir.appendingPathComponent(String(format: "IMG_%04d.DNG", i))
            try Data(repeating: UInt8(i % 251 + 1), count: 128 * 1024).write(to: url)
            bundles.append(AssetBundle(
                primary: ScannedPhoto(id: url, url: url, size: 128 * 1024,
                                      dateTaken: Date(timeIntervalSince1970: 1_716_000_000),
                                      dateSource: .fileModification),
                companions: []))
        }
        let folder = DestinationFolder(id: "2026/2026-05-18", year: 2026,
                                       dayDate: Date(timeIntervalSince1970: 1_716_000_000),
                                       dayName: "2026-05-18", bundles: bundles)
        return YearGroup(id: 2026, year: 2026, folders: [folder])
    }

    // MARK: - T4-2 · quitting mid-copy

    /// Quit was wired straight to `NSApp.terminate(nil)`. `FileCopier`'s partial
    /// cleanup is a Swift `catch`, which process death skips — and the orphan it
    /// leaves is invisible forever: absent from the manifest (written after the
    /// loop), never xattr-stamped, and on a re-ingest its size differs so dedup
    /// misses and `CopyPlan` disambiguates the *real* file to `…_1`. Neither
    /// verify mode can ever see it. So termination has to route through the
    /// graceful-cancel path that already writes a receipt — the same decision the
    /// CLI makes for SIGTERM.
    func testTerminationIsDeferredWhileAJobIsRunning() {
        XCTAssertEqual(TerminationPolicy.decide(hasRunningJob: true), .waitForTheJobToStop)
        XCTAssertEqual(TerminationPolicy.decide(hasRunningJob: false), .quitNow)
    }

    /// The registry is how a delegate — which owns no view state — finds the
    /// running job at all.
    func testARunningJobIsDiscoverableAndReleasedWhenItEnds() async throws {
        let dir = try freshDir()
        let registry = JobRegistry()
        XCTAssertNil(registry.runningCopier)

        let copier = Copier.hermetic(in: dir)
        copier.registry = registry
        copier.start(yearGroups: [try card(dir, files: 4)],
                     primaryDestination: dir.appendingPathComponent("lib", isDirectory: true),
                     archiveDestinations: [], description: "", verify: true, ejectAfter: false,
                     sourceMountPoint: nil, sourceVolumeID: "vol", template: .default, cardLabel: "CARD")
        XCTAssertTrue(registry.runningCopier === copier, "a delegate must be able to find the job")

        await copier.waitForCompletion()
        XCTAssertNil(registry.runningCopier, "a finished job must not keep the app from quitting")
    }

    /// Terminating cancels rather than killing, so the manifest and log for what
    /// already landed still get written — the receipt is the whole point.
    func testStoppingForTerminationLeavesAReceipt() async throws {
        let dir = try freshDir()
        let library = dir.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let copier = Copier.hermetic(in: dir)
        copier.start(yearGroups: [try card(dir, files: 24)], primaryDestination: library,
                     archiveDestinations: [], description: "", verify: true, ejectAfter: false,
                     sourceMountPoint: nil, sourceVolumeID: "vol", template: .default, cardLabel: "CARD")

        await copier.stopForTermination()

        switch copier.state {
        case .cancelled(let result), .completed(let result as CopyResult?):
            XCTAssertNotNil(result?.manifestURL, "a stopped job still owes a record of what landed")
        default:
            XCTFail("expected a terminal state carrying a receipt, got \(copier.state)")
        }
    }

    // MARK: - T4-4 · "Auto-open window" was inert in .withCard mode

    /// The observer lives on the MenuBarExtra's *label*, which in `.withCard` is
    /// created by the very drives-empty→non-empty transition it needs to see.
    /// Without an initial delivery it never fired, so the first card of a session
    /// never opened the window — the one mode where the setting matters most.
    func testTheFirstCardOfASessionCountsAsAnArrival() {
        XCTAssertTrue(MenuBarAutoOpen.shouldOpen(previous: ["card-a"], current: ["card-a"], isInitial: true),
                      "the label only exists because a card arrived")
        XCTAssertFalse(MenuBarAutoOpen.shouldOpen(previous: [], current: [], isInitial: true),
                       "no card, nothing to open for")
    }

    func testOnlyNewlyArrivedCardsOpenTheWindow() {
        XCTAssertTrue(MenuBarAutoOpen.shouldOpen(previous: [], current: ["card-a"], isInitial: false))
        XCTAssertTrue(MenuBarAutoOpen.shouldOpen(previous: ["card-a"], current: ["card-a", "card-b"], isInitial: false))
        XCTAssertFalse(MenuBarAutoOpen.shouldOpen(previous: ["card-a", "card-b"], current: ["card-a"], isInitial: false),
                       "ejecting a card must not raise a window")
        XCTAssertFalse(MenuBarAutoOpen.shouldOpen(previous: ["card-a"], current: ["card-a"], isInitial: false))
    }

    /// `.hidden` removes the menu bar entirely, and the menu bar is the host that
    /// detects arrivals — so the toggle cannot work there. Settings showed it
    /// plainly enabled in all three modes.
    func testAutoOpenIsOnlyAvailableWhenTheMenuBarExists() {
        XCTAssertTrue(MenuBarAutoOpen.isAvailable(for: .always))
        XCTAssertTrue(MenuBarAutoOpen.isAvailable(for: .withCard))
        XCTAssertFalse(MenuBarAutoOpen.isAvailable(for: .hidden))
    }
}

/// The card-selection rule, extracted from a closure inside `MainView.body`.
///
/// It lived inline as an if/else-if on `selectedSourceID` — untestable where it
/// was, and one of the two expressions the type checker still spent real time
/// on. Pulling it out is worth doing for the first reason alone.
@MainActor
final class DriveSelectionTests: XCTestCase {

    func testAStillPresentSelectionIsKept() {
        XCTAssertEqual(DriveSelection.reconcile(current: "b", drives: ["a", "b", "c"]), "b",
                       "inserting another card must not move the user's selection")
    }

    func testAnEjectedSelectionFallsBackToTheFirstCard() {
        XCTAssertEqual(DriveSelection.reconcile(current: "b", drives: ["a", "c"]), "a")
    }

    func testNoSelectionAdoptsTheFirstCard() {
        XCTAssertEqual(DriveSelection.reconcile(current: nil, drives: ["a", "b"]), "a")
    }

    func testNoCardsMeansNoSelection() {
        XCTAssertNil(DriveSelection.reconcile(current: "a", drives: []))
        XCTAssertNil(DriveSelection.reconcile(current: nil, drives: []))
    }
}
