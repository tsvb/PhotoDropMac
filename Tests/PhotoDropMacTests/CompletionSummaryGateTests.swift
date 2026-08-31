import XCTest
@testable import PhotoDropMac

/// §4.1: the `photodrop.showCompletionSheet` preference must actually gate the
/// completion summary. A clean finish with the setting off is suppressed, but a
/// finish that had failures is always surfaced (never silently hidden), and
/// non-completed states never present a summary.
final class CompletionSummaryGateTests: XCTestCase {
    private func completed(failed: Int) -> CopierState {
        .completed(CopyResult(
            bundleCount: 1, filesCopied: 3, filesSkipped: 0, filesFailed: failed,
            failuresByDestination: failed > 0 ? ["/tmp/lib": failed] : [:], failedFiles: [], duplicatesFoundElsewhere: [],
            totalBytes: 100, elapsedSeconds: 1,
            primaryDestination: URL(fileURLWithPath: "/tmp/lib"),
            logURL: nil, manifestURL: nil, manifestFailures: [], wasEjected: false, halted: false,
            haltReason: nil, cancelled: false))
    }

    func testShownForCleanCompletionWhenSettingOn() {
        XCTAssertTrue(completed(failed: 0).shouldPresentCompletionSummary(showSetting: true))
    }

    func testHiddenForCleanCompletionWhenSettingOff() {
        XCTAssertFalse(completed(failed: 0).shouldPresentCompletionSummary(showSetting: false))
    }

    func testShownOnFailuresEvenWhenSettingOff() {
        XCTAssertTrue(completed(failed: 2).shouldPresentCompletionSummary(showSetting: false))
    }

    func testNotShownForNonCompletedStates() {
        let progress = CopyProgress(totalBundles: 1, completedBundles: 0, verifiedBundles: 0,
                                    totalBytes: 1, bytesCopied: 0, elapsedSeconds: 0, currentFile: "")
        for state: CopierState in [.idle, .cancelled(nil), .failed("halted", nil), .running(progress)] {
            XCTAssertFalse(state.shouldPresentCompletionSummary(showSetting: true), "\(state)")
            XCTAssertFalse(state.shouldPresentCompletionSummary(showSetting: false), "\(state)")
        }
    }
}
