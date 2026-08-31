import XCTest
@testable import PhotoDropMac

/// T4 — what the app *says* about a job, and what it lets the user do about it.
///
/// These four defects share a shape: the engine already knew the truth and the
/// UI reported something else. That is the same class of failure as the Tier-1
/// completion text ("verified" when nothing was verified), and it matters here
/// for the same reason — the app's product is a trustworthy claim about the
/// user's photos.
@MainActor
final class JobSurfaceTests: XCTestCase {

    private func result(manifest: String? = "/lib/PhotoDrop Manifests/ingest-1.json",
                        log: String? = "/logs/ingest-1.log") -> CopyResult {
        CopyResult(
            bundleCount: 3, filesCopied: 3, filesSkipped: 0, filesFailed: 0,
            failuresByDestination: [:], failedFiles: [], duplicatesFoundElsewhere: [], landedFolders: [], totalBytes: 300, elapsedSeconds: 1,
            primaryDestination: URL(fileURLWithPath: "/lib"),
            logURL: log.map { URL(fileURLWithPath: $0) },
            manifestURL: manifest.map { URL(fileURLWithPath: $0) },
            manifestFailures: [],
            wasEjected: false, halted: true, haltReason: "verification mismatch",
            cancelled: false)
    }

    // MARK: - T4-1 · the halt and cancel paths dead-ended

    /// A halted job still wrote a `partial: true` manifest and a log, and the
    /// engine still returned both URLs — `Copier` threw them away to keep a bare
    /// string. So the one state where a user most needs the receipt was the one
    /// state that offered none, while the notification told them to "see the app
    /// for details" that did not exist.
    func testEveryTerminalStateCarriesItsReceipt() {
        let r = result()
        XCTAssertEqual(CopierState.completed(r).result, r)
        XCTAssertEqual(CopierState.cancelled(r).result, r)
        XCTAssertEqual(CopierState.failed("Halted: mismatch.", r).result, r)

        // …and the states that genuinely have no receipt say so.
        XCTAssertNil(CopierState.idle.result)
        XCTAssertNil(CopierState.cancelled(nil).result)
        XCTAssertNil(CopierState.failed("No photos to copy.", nil).result)
    }

    func testHaltPreservesTheManifestAndLogTheEngineWrote() {
        let state = CopierState.failed("Halted: verification mismatch. See log.", result())
        XCTAssertEqual(state.result?.manifestURL?.lastPathComponent, "ingest-1.json")
        XCTAssertEqual(state.result?.logURL?.lastPathComponent, "ingest-1.log")
    }

    // MARK: - The VERIFIED badge

    /// `ProgressPane` drove its mark from bytes copied and hard-coded the caption
    /// to VERIFIED, with the verify flag never passed in. Turning verification
    /// off in Settings changed nothing on the most prominent surface in the app —
    /// exactly the dishonesty the completion text was fixed for.
    func testTheTrustCaptionFollowsWhetherTheJobIsVerifying() {
        XCTAssertEqual(ProgressPane.trustCaption(verifying: true), "VERIFIED")
        XCTAssertEqual(ProgressPane.trustCaption(verifying: false), "COPIED")
    }

    /// The badge must follow *the running job*, not the current preference: a
    /// user who flips the setting mid-copy has not changed what this job did.
    func testTheCopierRemembersWhetherTheRunningJobVerifies() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobSurface-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let copier = Copier.hermetic(in: dir)
        XCTAssertTrue(copier.isVerifyingCurrentJob, "the default reflects the shipped default (verify on)")
        copier.start(yearGroups: [], primaryDestination: dir, archiveDestinations: [],
                     description: "", verify: false, ejectAfter: false,
                     sourceMountPoint: nil, sourceVolumeID: "vol", template: .default, cardLabel: "CARD")
        XCTAssertFalse(copier.isVerifyingCurrentJob)
    }

    // MARK: - T4-3 · culling was invisible outside the grid

    /// Deselect 400 of 500 in the contact sheet, switch to the tree, and it still
    /// read "500 files" beside a button that would copy 100.
    func testCountsReportTheSelectionNotEverythingDiscovered() {
        let groups = sampleGroups()
        let all = SelectionSummary.of(yearGroups: groups, deselected: [])
        XCTAssertEqual(all.files, 4)
        XCTAssertEqual(all.bytes, 400)

        let firstBundle = try! XCTUnwrap(groups.first?.folders.first?.bundles.first)
        let some = SelectionSummary.of(yearGroups: groups, deselected: [firstBundle.id])
        XCTAssertEqual(some.files, 3, "a deselected bundle is not going to be copied, so it is not counted")
        XCTAssertEqual(some.bytes, 300)

        let none = SelectionSummary.of(yearGroups: groups, deselected: Set(allBundleIDs(groups)))
        XCTAssertEqual(none.files, 0)
        XCTAssertEqual(none.bytes, 0)
    }

    // MARK: - One-click ingest could start a job nobody asked for

    /// `tryAutoIngest` returned without clearing the pending flag on any guard
    /// failure, and its only retry trigger was the end of a scan. One-click a
    /// card with no recognized photos → the flag stays armed → insert a
    /// *different* card later → it ingests with no user action at all.
    func testAnArmedOneClickRequestIsAbandonedWhenTheCardCannotSatisfyIt() {
        XCTAssertEqual(AutoIngestGate.decide(pending: true, isScanning: false, totalFiles: 0,
                                             hasDestination: true, copierIsRunning: false),
                       .abandon, "a scanned card with nothing on it can never satisfy the request")
        XCTAssertEqual(AutoIngestGate.decide(pending: true, isScanning: false, totalFiles: 12,
                                             hasDestination: false, copierIsRunning: false),
                       .abandon, "no destination is configured — the request cannot be honoured")
        XCTAssertEqual(AutoIngestGate.decide(pending: true, isScanning: false, totalFiles: 12,
                                             hasDestination: true, copierIsRunning: true),
                       .abandon, "a job is already running; this request is stale")
    }

    func testTheGateWaitsWhileScanningAndStartsWhenReady() {
        XCTAssertEqual(AutoIngestGate.decide(pending: true, isScanning: true, totalFiles: 0,
                                             hasDestination: true, copierIsRunning: false),
                       .wait, "the scan hasn't answered yet")
        XCTAssertEqual(AutoIngestGate.decide(pending: true, isScanning: false, totalFiles: 12,
                                             hasDestination: true, copierIsRunning: false),
                       .start)
    }

    func testAnUnarmedGateNeverStartsAnything() {
        for scanning in [true, false] {
            XCTAssertEqual(AutoIngestGate.decide(pending: false, isScanning: scanning, totalFiles: 12,
                                                 hasDestination: true, copierIsRunning: false),
                           .idle)
        }
    }

    // MARK: - Fixtures

    private func allBundleIDs(_ groups: [YearGroup]) -> [AssetBundle.ID] {
        groups.flatMap { $0.folders.flatMap { $0.bundles.map(\.id) } }
    }

    private func sampleGroups() -> [YearGroup] {
        let date = Date(timeIntervalSince1970: 1_716_000_000)
        let bundles = (0..<4).map { i -> AssetBundle in
            let url = URL(fileURLWithPath: "/card/IMG_000\(i).CR2")
            return AssetBundle(primary: ScannedPhoto(id: url, url: url, size: 100,
                                                     dateTaken: date, dateSource: .exif),
                               companions: [])
        }
        let folder = DestinationFolder(id: "2026/2026-05-18", year: 2026, dayDate: date,
                                       dayName: "2026-05-18", bundles: bundles)
        return [YearGroup(id: 2026, year: 2026, folders: [folder])]
    }
}
