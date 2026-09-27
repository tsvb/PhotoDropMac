import XCTest
@testable import PhotoDropMac

/// Destination-name collisions the `_1` disambiguator could not see.
///
/// **Threat model.** Filenames come off the card, which is adversary-authored in
/// the general case and merely inconsistent in the common one. The disambiguator
/// is what stops two source files from planning onto one destination path; when
/// it cannot see a collision, `FileCopier`'s `O_EXCL` refuses the second write and
/// the whole bundle fails and rolls back — permanently, on every re-run.
///
/// **Measured before-state.** `CopyPlan.planBatch` compared `taken.contains(url.path)`
/// — exact strings — while APFS is case-insensitive by default. Running the real
/// `planBatch`: `IMG_0001.JPG` → `20260528_162640_IMG_0001.JPG` and
/// `img_0001.jpg` → `20260528_162640_img_0001.jpg`, two distinct strings naming
/// one file on disk, and `_1` never fired. Separately, `taken.insert` ran *after*
/// `plan` returned, so a collision between two files of the same bundle was
/// structurally invisible: `IMG_1234.xmp` and `IMG_1234.v2.xmp` (both short-form
/// sidecars by `classifyCompanion`'s prefix rule) planned onto one path.
///
/// **Truncation undid the separation, forever.** `separateInternalCollisions`
/// built each retry with `PathPlanner.fileName(stem: "<stem>_<n>", …)`, which
/// trims the stem's *end* to fit NAME_MAX — the `_n`. A card holding `S.CR2`,
/// `S.CR2.xmp` and `S.xmp` with a 235–247 character `S` renders a 251-byte stem;
/// both sidecars trim to one `<stem>.xmp`, and every retry trimmed back to it.
/// Traced from the code and reproduced with a port of the arithmetic (10,000
/// iterations, no escape): the planner spun before the engine's first cancel
/// check, so Cancel, Ctrl-C and Quit all hung — from card insertion alone with
/// one-click ingest on.
final class CopyPlanCollisionTests: XCTestCase {

    private func captureDate() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 28; c.hour = 12; c.minute = 0; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func photo(_ name: String, in dir: URL) -> ScannedPhoto {
        let url = dir.appendingPathComponent(name)
        return ScannedPhoto(id: url, url: url, size: 4096,
                            dateTaken: captureDate(), dateSource: .exif)
    }

    private func bundle(_ name: String, companions: [(String, CompanionKind)] = [],
                        in dir: URL) -> AssetBundle {
        AssetBundle(
            primary: photo(name, in: dir),
            companions: companions.map { entry in
                CompanionFile(url: dir.appendingPathComponent(entry.0), size: 16, kind: entry.1)
            }
        )
    }

    private let root = URL(fileURLWithPath: "/dest", isDirectory: true)
    private let card = URL(fileURLWithPath: "/card", isDirectory: true)

    // MARK: - Case-insensitive destinations

    /// The measured case: same capture second, names differing only in case.
    func testNamesDifferingOnlyInCaseGetDisambiguated() {
        let plans = CopyPlan.planBatch(
            bundles: [bundle("IMG_0001.JPG", in: card), bundle("img_0001.jpg", in: card)],
            destinationRoot: root, description: "", template: .default, cardLabel: "")

        let paths = plans.flatMap { $0.files.map(\.destination.path) }
        XCTAssertEqual(paths.count, 2)
        XCTAssertNotEqual(paths[0].lowercased(), paths[1].lowercased(),
                          "on a case-insensitive volume these are the same file: \(paths)")
    }

    /// The common real-world trigger is extension casing against a name already
    /// on disk — the union of existing names is folded too, not just the batch.
    func testExistingPathDifferingOnlyInExtensionCaseIsHonoured() {
        let taken = "/dest/2026/2026-05-28/20260528_120000_IMG_0001.jpg"
        let plans = CopyPlan.planBatch(
            bundles: [bundle("IMG_0001.JPG", in: card)],
            destinationRoot: root, description: "", template: .default,
            cardLabel: "", existingPaths: [taken])

        let planned = plans[0].files[0].destination.path
        XCTAssertNotEqual(planned.lowercased(), taken.lowercased(),
                          "the on-disk file is the same name in a different case; planning onto it earns EEXIST")
        XCTAssertTrue(planned.contains("_1"), "expected a disambiguator, got \(planned)")
    }

    /// Folding must not disturb the ordinary case: distinct names stay
    /// suffix-free, so filenames don't grow `_1` for no reason.
    func testDistinctNamesAreUnaffected() {
        let plans = CopyPlan.planBatch(
            bundles: [bundle("IMG_0001.JPG", in: card), bundle("IMG_0002.JPG", in: card)],
            destinationRoot: root, description: "", template: .default, cardLabel: "")
        for path in plans.flatMap({ $0.files.map(\.destination.path) }) {
            XCTAssertFalse(path.contains("_1."), "gratuitous disambiguator in \(path)")
        }
    }

    /// Unicode: a decomposed (NFD) name and a composed (NFC) one are one file.
    func testCanonicallyEquivalentNamesCollide() {
        let nfc = "Cafe\u{0301}".precomposedStringWithCanonicalMapping   // "Café"
        let nfd = "Cafe\u{0301}".decomposedStringWithCanonicalMapping
        let plans = CopyPlan.planBatch(
            bundles: [bundle("\(nfc).JPG", in: card), bundle("\(nfd).JPG", in: card)],
            destinationRoot: root, description: "", template: .default, cardLabel: "")
        let keys = plans.flatMap { $0.files.map { CopyPlan.collisionKey($0.destination.path) } }
        XCTAssertEqual(Set(keys).count, 2, "the two bundles must not share a destination key")
    }

    // MARK: - Collisions inside one bundle

    /// Two sidecars that both render to `{newStem}.xmp`. Before, they planned
    /// onto one path and `O_EXCL` failed the entire bundle — the RAW with it.
    func testTwoSidecarsRenderingToTheSameNameAreSeparated() {
        let plan = CopyPlan.plan(
            bundle: bundle("IMG_1234.CR2",
                           companions: [("IMG_1234.xmp", CompanionKind.xmp), ("IMG_1234.v2.xmp", CompanionKind.xmp)],
                           in: card),
            destinationRoot: root, description: "", template: .default, cardLabel: "")

        let paths = plan.files.map(\.destination.path)
        XCTAssertEqual(paths.count, 3, "every file in the bundle is still planned — none dropped")
        XCTAssertEqual(Set(paths.map(CopyPlan.collisionKey)).count, 3,
                       "each file needs its own path: \(paths)")
        XCTAssertTrue(paths[0].hasSuffix(".CR2"), "the primary is index 0 and is never the one moved")
    }

    /// The separation is stable under an *external* collision too: bumping the
    /// primary's `_n` re-derives everything, and the result must still be
    /// internally distinct rather than the loop spinning.
    func testInternalSeparationSurvivesAnExternalDisambiguator() {
        let taken = "/dest/2026/2026-05-28/20260528_120000_IMG_1234.CR2"
        let plans = CopyPlan.planBatch(
            bundles: [bundle("IMG_1234.CR2",
                             companions: [("IMG_1234.xmp", CompanionKind.xmp), ("IMG_1234.v2.xmp", CompanionKind.xmp)],
                             in: card)],
            destinationRoot: root, description: "", template: .default,
            cardLabel: "", existingPaths: [taken])

        let paths = plans[0].files.map(\.destination.path)
        XCTAssertEqual(Set(paths.map(CopyPlan.collisionKey)).count, 3)
        XCTAssertTrue(paths[0].contains("_1.CR2"), "the primary moved around the on-disk file: \(paths[0])")
    }

    // MARK: - Truncation must not undo the separation

    /// The crafted card from the header. Run under a watchdog: the defect is a
    /// hang, and a timeout **fails** here rather than stalling the suite.
    func testMaximumLengthSidecarsCollidingAfterTruncationStillSeparate() {
        let stem = String(repeating: "A", count: 240)
        let crafted = self.bundle("\(stem).CR2",
                                  companions: [("\(stem).CR2.xmp", CompanionKind.xmp),
                                               ("\(stem).xmp", CompanionKind.xmp)],
                                  in: card)
        let destRoot = self.root
        let box = PlanBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.plan = CopyPlan.plan(bundle: crafted, destinationRoot: destRoot,
                                     description: "", template: .default, cardLabel: "")
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success, let plan = box.plan else {
            return XCTFail("planning spun forever — the `_n` was truncated back off every retry")
        }

        let paths = plan.files.map(\.destination.path)
        XCTAssertEqual(paths.count, 3, "every file in the bundle is still planned — none dropped")
        XCTAssertEqual(Set(paths.map(CopyPlan.collisionKey)).count, 3, "each file needs its own path: \(paths)")
        for path in paths {
            XCTAssertLessThanOrEqual((path as NSString).lastPathComponent.utf8.count,
                                     PathPlanner.maxComponentBytes, "over NAME_MAX: \(path)")
        }
    }
}

/// Carries the planner's result out of the watchdog's background queue.
private final class PlanBox: @unchecked Sendable {
    var plan: BundlePlan?
}
