import XCTest
@testable import PhotoDropMac

/// The pre-copy free-space warning. Previously untested.
///
/// It is deliberately conservative (assumes no dedup savings, sums per volume,
/// so two destinations on one disk need 2×) and deliberately best-effort (a
/// volume it cannot resolve is skipped rather than reported). Both properties
/// are easy to "tidy" into something that either nags or stays silent when it
/// matters, so they are pinned here.
final class PreflightCheckTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreflightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { [tmp] in try? FileManager.default.removeItem(at: tmp!) }
    }

    /// More than any real volume has free, so the check must fire.
    private let impossible: Int64 = 1 << 60   // 1 EiB

    func testNoWarningWhenNothingIsPlanned() {
        XCTAssertNil(PreflightCheck.spaceWarning(plannedBytes: 0, primary: tmp, archives: []))
    }

    func testNoWarningWhenItComfortablyFits() {
        XCTAssertNil(PreflightCheck.spaceWarning(plannedBytes: 1024, primary: tmp, archives: []))
    }

    func testWarnsWhenThePlannedBytesCannotFit() throws {
        let warning = try XCTUnwrap(PreflightCheck.spaceWarning(plannedBytes: impossible,
                                                                primary: tmp, archives: []))
        XCTAssertTrue(warning.contains("free"), warning)
        XCTAssertTrue(warning.lowercased().contains("duplicate"),
                      "the warning must say it may still fit — dedup isn't accounted for")
    }

    /// Two destinations on the same volume need twice the space. Nothing else in
    /// the app knows that, so this check is the only place it is stated.
    func testTwoDestinationsOnOneVolumeSumTheirRequirement() throws {
        let a = tmp.appendingPathComponent("a", isDirectory: true)
        let b = tmp.appendingPathComponent("b", isDirectory: true)
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        let free = try XCTUnwrap(
            (try? tmp.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage)
        // Fits once, but not twice.
        let each = Int64(Double(free) * 0.6)
        try XCTSkipIf(each <= 0, "no capacity reading available on this volume")

        XCTAssertNil(PreflightCheck.spaceWarning(plannedBytes: each, primary: a, archives: []))
        XCTAssertNotNil(PreflightCheck.spaceWarning(plannedBytes: each, primary: a, archives: [b]),
                        "the same bytes written twice to one volume need twice the room")
    }

    /// Regression: the check iterated a `Dictionary` and returned on the first
    /// over-capacity volume, so with two full destinations the volume it named
    /// changed from run to run. A warning that fingers a different disk each
    /// time is not actionable.
    func testWarningIsDeterministicAcrossRuns() throws {
        let a = tmp.appendingPathComponent("a", isDirectory: true)
        let b = tmp.appendingPathComponent("b", isDirectory: true)
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        let results = Set((0..<25).map { _ in
            PreflightCheck.spaceWarning(plannedBytes: impossible, primary: a, archives: [b]) ?? "nil"
        })
        XCTAssertEqual(results.count, 1, "same inputs must always name the same volume: \(results)")
    }

    /// Best-effort by design: an archive folder that doesn't exist yet (an
    /// unplugged drive, a folder the job will create) is skipped, not reported
    /// as a problem.
    func testUnresolvableDestinationIsSkippedNotReported() {
        let ghost = URL(fileURLWithPath: "/Volumes/DefinitelyNotMounted-\(UUID().uuidString)")
        XCTAssertNil(PreflightCheck.spaceWarning(plannedBytes: 1024, primary: ghost, archives: []))
    }
}

// MARK: - Topology (the GUI's copy of the engine's refusal)

/// The engine refuses overlapping trees for every caller; this is the check that
/// lets the GUI say so *before* the user presses Ingest rather than after the job
/// halts. It is deliberately not a warning — see `PreflightCheck.topologyRefusal`.
extension PreflightCheckTests {

    func testTopologyRefusalNamesTheOverlap() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreflightTopology-\(UUID().uuidString)", isDirectory: true)
        let library = tmp.appendingPathComponent("Library", isDirectory: true)
        let card = library.appendingPathComponent("card", isDirectory: true)
        let mirror = tmp.appendingPathComponent("Mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }

        let refusal = try XCTUnwrap(
            PreflightCheck.topologyRefusal(source: card, primary: library, archives: []))
        XCTAssertTrue(refusal.contains("is inside the destination"), refusal)

        XCTAssertNil(PreflightCheck.topologyRefusal(source: nil, primary: library, archives: [mirror]),
                     "disjoint destinations are the normal case")
        XCTAssertNotNil(PreflightCheck.topologyRefusal(
            source: nil, primary: library, archives: [library.appendingPathComponent("Backup")]),
                        "a mirror inside the primary is not an independent copy")
    }
}
