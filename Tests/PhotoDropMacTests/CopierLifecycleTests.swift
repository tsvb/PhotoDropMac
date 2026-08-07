import XCTest
@testable import PhotoDropMac

/// Cancel → Reset → Ingest: the state machine around a superseded run.
///
/// **Threat model.** The visible log is the surface this app asks the user to
/// trust about what happened to their photos, and the panel is what tells them a
/// job is over. Neither may carry another job's content.
///
/// **Measured before-state.** `Copier.reset()` cleared `state`, `log` and `task`
/// but left `cancelFlag` intact, so the in-flight engine's completion guard
/// (`self.cancelFlag === flag`) still matched: after the engine finished its tail
/// — rollback, fsync, manifest, log, cache save — it set `state = .cancelled(result)`,
/// making the app jump from an idle screen back to the "Ingest cancelled" panel
/// with no user action. And the `onProgress`/`onLog` MainActor hops carried no
/// generation check at all, unlike the result path, so job 1's tail lines
/// ("Ingest cancelled after 12.3s…", "Complete: 40 copied…") appended into job 2's
/// visible log *after* `log.removeAll()`, and `applyProgress` overwrote job 2's
/// counters.
@MainActor
final class CopierLifecycleTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopierLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func captureDate() -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 28; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    /// Enough bundles that a cancel lands mid-job rather than after it.
    private func yearGroup(count: Int, in tmp: URL) throws -> YearGroup {
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        var bundles: [AssetBundle] = []
        for i in 1...count {
            let url = card.appendingPathComponent(String(format: "IMG_%04d.DNG", i))
            try Data(repeating: UInt8(i % 251 + 1), count: 256 * 1024).write(to: url)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bundles.append(AssetBundle(
                primary: ScannedPhoto(id: url, url: url, size: Int64(size),
                                      dateTaken: captureDate(), dateSource: .fileModification),
                companions: []))
        }
        let folder = DestinationFolder(id: "2026/2026-05-28", year: 2026, dayDate: captureDate(),
                                       dayName: "2026-05-28", bundles: bundles)
        return YearGroup(id: 2026, year: 2026, folders: [folder])
    }

    private func start(_ copier: Copier, _ groups: [YearGroup], dest: URL) {
        copier.start(yearGroups: groups, primaryDestination: dest, archiveDestinations: [],
                     description: "", verify: true, ejectAfter: false, sourceMountPoint: nil,
                     sourceVolumeID: "test-vol", template: .default, cardLabel: "")
    }

    private func settle(_ copier: Copier, seconds: Double = 5) async throws {
        var ticks = 0
        let limit = Int(seconds / 0.025)
        while copier.isRunning && ticks < limit {
            try await Task.sleep(nanoseconds: 25_000_000)
            ticks += 1
        }
        XCTAssertFalse(copier.isRunning, "the copier never settled — a hang, not a pass")
    }

    /// The engine keeps running after `cancel()` (it has a manifest and log to
    /// write). `reset()` must retire that generation so it can never repaint the
    /// UI the user has already dismissed.
    func testResetPreventsASupersededRunFromRepaintingTheUI() async throws {
        let tmp = try freshTempDir()
        let copier = Copier.hermetic(in: tmp)
        let dest = tmp.appendingPathComponent("library", isDirectory: true)

        start(copier, [try yearGroup(count: 40, in: tmp)], dest: dest)
        copier.cancel()
        copier.reset()
        XCTAssertTrue(copier.state.isIdle)

        // Give the engine well past the time it needs to finish its tail.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(copier.state.isIdle,
                      "the dismissed run came back and repainted the panel: \(copier.state)")
        XCTAssertTrue(copier.log.isEmpty, "and it appended to a log the user had cleared")
    }

    /// A second job's log must contain only the second job's lines.
    func testASupersededRunsLogLinesDoNotLeakIntoTheNextJob() async throws {
        let tmp = try freshTempDir()
        let copier = Copier.hermetic(in: tmp)
        let dest = tmp.appendingPathComponent("library", isDirectory: true)
        let groups = [try yearGroup(count: 40, in: tmp)]

        start(copier, groups, dest: dest)
        copier.cancel()

        // Start a second job immediately — `start` cancels the first and mints a
        // new generation, and the first is still writing its tail.
        let second = tmp.appendingPathComponent("library2", isDirectory: true)
        start(copier, groups, dest: second)
        try await settle(copier)
        try await Task.sleep(nanoseconds: 500_000_000)   // let any straggler hop land

        XCTAssertFalse(copier.log.contains { $0.line.contains("Ingest cancelled") },
                       "the first job's cancellation line appeared in the second job's log")
        XCTAssertEqual(copier.log.filter { $0.line.hasPrefix("Starting ingest") }.count, 1,
                       "exactly one job's worth of log: \(copier.log.map(\.line))")
    }

    /// `cancel()` is idempotent and cancel-then-start does not race the result
    /// path — the pre-existing identity check covers that, and this pins it.
    func testCancelIsIdempotentAndRestartCompletesNormally() async throws {
        let tmp = try freshTempDir()
        let copier = Copier.hermetic(in: tmp)
        let dest = tmp.appendingPathComponent("library", isDirectory: true)
        let groups = [try yearGroup(count: 4, in: tmp)]

        start(copier, groups, dest: dest)
        copier.cancel()
        copier.cancel()
        copier.reset()

        start(copier, groups, dest: tmp.appendingPathComponent("library2", isDirectory: true))
        try await settle(copier)
        guard case .completed(let result) = copier.state else {
            return XCTFail("expected the restarted job to complete, got \(copier.state)")
        }
        XCTAssertEqual(result.filesCopied, 4)
        XCTAssertEqual(result.filesFailed, 0)
    }
}

private extension CopierState {
    var isIdle: Bool { if case .idle = self { return true }; return false }
}
