import XCTest
@testable import PhotoDropMac

/// Tests the collision-safe naming in `CopyPlan` — the second guard (after the
/// copy engine's `O_EXCL`) against two files landing on the same destination
/// path. These are pure path computations; no filesystem is touched.
final class CopyPlanTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/pdm-library", isDirectory: true)

    private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return Calendar.current.date(from: c)!
    }

    private func bundle(dir: String, name: String, date: Date,
                        companions: [CompanionFile] = []) -> AssetBundle {
        let url = URL(fileURLWithPath: "/Volumes/CARD/\(dir)/\(name)")
        let photo = ScannedPhoto(id: url, url: url, size: 1_000, dateTaken: date, dateSource: .exif)
        return AssetBundle(primary: photo, companions: companions)
    }

    // Two distinct files whose capture-second and stem collide must not plan
    // onto the same destination path; the second gets a numeric disambiguator.
    func testCollidingBundlesGetDisambiguated() {
        let date = localDate(2026, 5, 28, 12, 0, 0)
        let a = bundle(dir: "100", name: "IMG_0001.JPG", date: date)
        let b = bundle(dir: "101", name: "IMG_0001.JPG", date: date)

        let plans = CopyPlan.planBatch(bundles: [a, b], destinationRoot: root,
                                       description: "", template: .default, cardLabel: "")
        XCTAssertEqual(plans.count, 2)
        let d0 = plans[0].files[0].destination
        let d1 = plans[1].files[0].destination
        XCTAssertNotEqual(d0, d1, "two bundles must never plan onto the same destination path")
        XCTAssertFalse(d0.deletingPathExtension().lastPathComponent.hasSuffix("_1"))
        XCTAssertTrue(d1.deletingPathExtension().lastPathComponent.hasSuffix("_1"),
                      "the second colliding bundle gets a _1 suffix")
    }

    // A name already present on disk (seeded via existingPaths) must be avoided.
    func testExistingPathOnDiskForcesDisambiguation() {
        let date = localDate(2026, 5, 28, 12, 0, 0)
        let a = bundle(dir: "100", name: "IMG_0001.JPG", date: date)

        let bare = CopyPlan.plan(bundle: a, destinationRoot: root, description: "",
                                 template: .default, cardLabel: "").files[0].destination
        let plans = CopyPlan.planBatch(bundles: [a], destinationRoot: root, description: "",
                                       template: .default, cardLabel: "", existingPaths: [bare.path])
        let planned = plans[0].files[0].destination
        XCTAssertNotEqual(planned, bare)
        XCTAssertTrue(planned.deletingPathExtension().lastPathComponent.hasSuffix("_1"))
    }

    // When the primary is disambiguated, its companions must follow the new stem
    // so the bundle's stem relationship survives the move.
    func testCompanionsFollowDisambiguatedPrimaryStem() {
        let date = localDate(2026, 5, 28, 12, 0, 0)
        let dng = URL(fileURLWithPath: "/Volumes/CARD/100/IMG_0001.DNG")
        let xmp = URL(fileURLWithPath: "/Volumes/CARD/100/IMG_0001.xmp")   // short-form sidecar
        let photo = ScannedPhoto(id: dng, url: dng, size: 1_000, dateTaken: date, dateSource: .exif)
        let b = AssetBundle(primary: photo, companions: [CompanionFile(url: xmp, size: 10, kind: .xmp)])

        let barePrimaryPath = CopyPlan.plan(bundle: b, destinationRoot: root, description: "",
                                            template: .default, cardLabel: "").files[0].destination.path
        let files = CopyPlan.planBatch(bundles: [b], destinationRoot: root, description: "",
                                       template: .default, cardLabel: "",
                                       existingPaths: [barePrimaryPath])[0].files

        let primaryStem = files[0].destination.deletingPathExtension().lastPathComponent
        let companionStem = files[1].destination.deletingPathExtension().lastPathComponent
        XCTAssertEqual(primaryStem, companionStem, "companion must share the disambiguated primary stem")
        XCTAssertTrue(primaryStem.hasSuffix("_1"))
        XCTAssertEqual(files[1].destination.pathExtension, "xmp")
    }

    // Year is the fixed top level; the day-folder leaf follows the template; the
    // original extension is preserved.
    func testDestinationLayoutYearDayFolderAndExtension() {
        let date = localDate(2026, 5, 28, 12, 0, 0)
        let a = bundle(dir: "100", name: "IMG_0001.JPG", date: date)
        let dest = CopyPlan.plan(bundle: a, destinationRoot: root, description: "Iceland",
                                 template: .default, cardLabel: "").files[0].destination

        let comps = dest.pathComponents
        XCTAssertTrue(comps.contains("2026"), "year is the fixed top level")
        XCTAssertTrue(comps.contains("2026-05-28_Iceland"), "day-folder leaf follows the template")
        XCTAssertEqual(dest.pathExtension, "JPG", "the original extension is preserved")
    }

    // §3.2: a very long description must yield a filesystem-safe day-folder leaf
    // (≤ NAME_MAX) rather than a name that aborts directory creation.
    func testLongDescriptionYieldsFilesystemSafeFolderLeaf() {
        let date = localDate(2026, 5, 28, 12, 0, 0)
        let a = bundle(dir: "100", name: "IMG_0001.JPG", date: date)
        let dest = CopyPlan.plan(bundle: a, destinationRoot: root,
                                 description: String(repeating: "x", count: 500),
                                 template: .default, cardLabel: "").files[0].destination
        let leaf = dest.deletingLastPathComponent().lastPathComponent
        XCTAssertLessThanOrEqual(leaf.utf8.count, PathPlanner.maxComponentBytes)
        XCTAssertTrue(leaf.hasPrefix("2026-05-28_"), "leaf still starts with the date prefix")
    }

    // MARK: - Nested folder templates

    func testFolderTemplateNestsBelowYear() {
        let date = localDate(2026, 5, 28, 12, 0, 0)
        let a = bundle(dir: "100", name: "IMG_0001.JPG", date: date)
        let template = NamingTemplate(folder: "{MM}/{yyyy-MM-dd}", filename: NamingTemplate.default.filename)
        let dest = CopyPlan.plan(bundle: a, destinationRoot: root, description: "",
                                 template: template, cardLabel: "").files[0].destination

        // …/2026/05/2026-05-28/<file>.JPG
        let underRoot = dest.pathComponents.drop(while: { $0 != "2026" })
        XCTAssertEqual(Array(underRoot.prefix(3)), ["2026", "05", "2026-05-28"])
        XCTAssertEqual(dest.pathExtension, "JPG")
    }

    func testDescriptionCannotInjectNesting() {
        // A "/" in the description is sanitized to "-" before interpolation, so
        // it stays within one folder component — only the template author nests.
        let date = localDate(2026, 5, 28, 12, 0, 0)
        let a = bundle(dir: "100", name: "IMG_0001.JPG", date: date)
        let dest = CopyPlan.plan(bundle: a, destinationRoot: root, description: "a/b",
                                 template: .default, cardLabel: "").files[0].destination
        let leaf = dest.deletingLastPathComponent().lastPathComponent
        XCTAssertEqual(leaf, "2026-05-28_a-b")
    }

    // The preview grouping (PathPlanner.plan) and the copy directory
    // (CopyPlan.destinationDirectory) must agree on the path below the year,
    // including when nested.
    func testPreviewGroupingAgreesWithNestedCopyDirectory() {
        let date = localDate(2026, 5, 28, 12, 0, 0)
        let a = bundle(dir: "100", name: "IMG_0001.JPG", date: date)
        let template = NamingTemplate(folder: "{MM}/{yyyy-MM-dd}", filename: NamingTemplate.default.filename)

        let groups = PathPlanner.plan(bundles: [a], description: "", template: template, cardLabel: "")
        let folder = groups.first?.folders.first
        XCTAssertEqual(folder?.dayName, "05/2026-05-28")

        let dir = CopyPlan.destinationDirectory(for: a, destinationRoot: root,
                                                description: "", template: template, cardLabel: "")
        let relUnderYear = dir.pathComponents.drop(while: { $0 != "2026" }).dropFirst().joined(separator: "/")
        XCTAssertEqual(relUnderYear, folder?.dayName, "preview folder must equal the copy's path below the year")
    }
}
