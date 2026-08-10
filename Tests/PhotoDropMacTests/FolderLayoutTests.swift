import XCTest
@testable import PhotoDropMac

/// Named folder layouts, and the optional year level they needed.
///
/// The destination shape was `{root}/{yyyy}/{day}/{file}` with the **year fixed
/// as the top level** — so the most-requested layout,
/// `{root}/2026-05-28/IMG_0001.jpg`, could not be expressed at all no matter
/// what you typed into the templates.
///
/// The load-bearing rule while changing this: **`PathPlanner.plan` (the preview
/// tree) and `CopyPlan.destinationDirectory` (where bytes actually land) must
/// agree.** They are computed by different code from the same template, and a
/// preview that shows one tree while the copy builds another is exactly the kind
/// of dishonesty this app exists not to commit. Every layout below is asserted
/// against *both*.
final class FolderLayoutTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/Volumes/Photos", isDirectory: true)

    /// 2026-05-28 14:30:22 local.
    private func bundle(named name: String = "IMG_0001.CR2") -> AssetBundle {
        var components = DateComponents()
        components.year = 2026; components.month = 5; components.day = 28
        components.hour = 14; components.minute = 30; components.second = 22
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: components)!
        let url = URL(fileURLWithPath: "/card/DCIM/\(name)")
        return AssetBundle(
            primary: ScannedPhoto(id: url, url: url, size: 1024, dateTaken: date, dateSource: .exif),
            companions: [])
    }

    /// The relative path a layout actually produces, from the copy engine.
    private func copyPath(_ template: NamingTemplate, description: String = "") -> String {
        let b = bundle()
        let dir = CopyPlan.destinationDirectory(for: b, destinationRoot: root,
                                                description: description, template: template, cardLabel: "")
        let plan = CopyPlan.plan(bundle: b, destinationRoot: root,
                                 description: description, template: template, cardLabel: "")
        let file = plan.files.first!.destination.lastPathComponent
        return dir.path.replacingOccurrences(of: root.path + "/", with: "") + "/" + file
    }

    /// The same path as the preview tree builds it.
    private func previewPath(_ template: NamingTemplate, description: String = "") -> String {
        let groups = PathPlanner.plan(bundles: [bundle()], description: description,
                                      template: template, cardLabel: "")
        let folder = groups.first!.folders.first!
        return folder.relativePath
    }

    // MARK: - The year level is now a choice

    func testTheYearLevelCanBeTurnedOff() {
        let layout = NamingTemplate(folder: "{yyyy-MM-dd}", filename: "{OriginalStem}", yearFolder: false)
        XCTAssertEqual(copyPath(layout), "2026-05-28/IMG_0001.CR2")
    }

    /// The shipped default is unchanged — an existing library must keep landing
    /// exactly where it always has.
    func testTheDefaultStillNestsUnderTheYear() {
        XCTAssertTrue(NamingTemplate.default.yearFolder)
        XCTAssertEqual(copyPath(NamingTemplate.default, description: ""),
                       "2026/2026-05-28/20260528_143022_IMG_0001.CR2")
    }

    func testPreviewAndCopyAgreeWithAndWithoutTheYearLevel() {
        for yearFolder in [true, false] {
            let layout = NamingTemplate(folder: "{yyyy-MM-dd}", filename: "{OriginalStem}",
                                        yearFolder: yearFolder)
            XCTAssertEqual(previewPath(layout), copyPath(layout).replacingOccurrences(of: "/IMG_0001.CR2", with: ""),
                           "the preview tree and the copy disagree (yearFolder: \(yearFolder))")
        }
    }

    /// A nested folder template still works without the year — the template
    /// author, not the app, decides the depth.
    func testATemplateCanStillNestItsOwnSubfolders() {
        let layout = NamingTemplate(folder: "{yyyy}/{MM}/{yyyy-MM-dd}", filename: "{OriginalStem}",
                                    yearFolder: false)
        XCTAssertEqual(copyPath(layout), "2026/05/2026-05-28/IMG_0001.CR2")
    }

    // MARK: - The built-in layouts

    func testDateAndOriginalName() {
        XCTAssertEqual(copyPath(FolderLayout.dateAndOriginalName.template),
                       "2026-05-28/IMG_0001.CR2")
    }

    func testDateAndTimestampedName() {
        XCTAssertEqual(copyPath(FolderLayout.dateAndTimestampedName.template),
                       "2026-05-28/20260528_143022_IMG_0001.CR2")
    }

    func testYearThenDateAndOriginalName() {
        XCTAssertEqual(copyPath(FolderLayout.yearDateAndOriginalName.template),
                       "2026/2026-05-28/IMG_0001.CR2")
    }

    func testDateAndDescription() {
        XCTAssertEqual(copyPath(FolderLayout.dateAndDescription.template, description: "Wedding"),
                       "2026-05-28_Wedding/IMG_0001.CR2")
        // The description is optional in that template: with none, the folder is
        // just the date rather than a trailing underscore.
        XCTAssertEqual(copyPath(FolderLayout.dateAndDescription.template, description: ""),
                       "2026-05-28/IMG_0001.CR2")
    }

    /// Each layout advertises a sample path in the UI. A sample that doesn't
    /// match what the engine does is a lie in the one place the user is deciding
    /// what to trust — so it is generated from the same renderer, and pinned.
    func testEveryLayoutsAdvertisedSampleIsWhatTheEngineProduces() {
        let b = bundle()
        let context = TemplateContext(date: b.primary.dateTaken,
                                      description: PathPlanner.sanitize("Wedding"),
                                      originalName: "IMG_0001.CR2", originalStem: "IMG_0001",
                                      cardLabel: "")
        for layout in FolderLayout.builtIn {
            let produced = copyPath(layout.template, description: "Wedding")
            XCTAssertEqual(layout.samplePath(context: context, fileExtension: "CR2"), produced,
                           "\(layout.name) advertises a path it does not produce")
        }
    }

    func testTheBuiltInLayoutsAreTheFourOffered() {
        XCTAssertEqual(FolderLayout.builtIn.map(\.name),
                       ["Date + original name",
                        "Date + timestamped name",
                        "Year / date + original name",
                        "Date + description"])
    }

    // MARK: - Applying a layout

    /// One method writes the settings, shared by the inspector and Settings →
    /// Naming. Two copies of "set these three keys" is how the two surfaces end
    /// up disagreeing about what a layout means.
    func testApplyingALayoutWritesAllThreeKeys() throws {
        let suite = UserDefaults(suiteName: "photodrop.tests.\(UUID().uuidString)")!
        FolderLayout.dateAndOriginalName.apply(to: suite)

        XCTAssertEqual(suite.string(forKey: IngestPreset.Keys.folder), "{yyyy-MM-dd}")
        XCTAssertEqual(suite.string(forKey: IngestPreset.Keys.filename), "{OriginalStem}")
        XCTAssertEqual(suite.object(forKey: IngestPreset.Keys.yearFolder) as? Bool, false,
                       "the year level is part of the layout — applying one must set it too")
    }

    /// The picker shows the matching layout, or "Custom". The shipped default is
    /// deliberately *not* one of the four, so a fresh install reads as Custom
    /// rather than mislabelling itself as a layout it isn't.
    func testTheShippedDefaultIsNotOneOfTheBuiltInLayouts() {
        XCTAssertNil(FolderLayout.matching(.default))
    }

    func testAppliedLayoutsAreRecognisedAfterwards() throws {
        for layout in FolderLayout.builtIn {
            XCTAssertEqual(FolderLayout.matching(layout.template), layout,
                           "\(layout.name) must read back as itself once applied")
        }
    }

    // MARK: - Round-tripping through a saved preset

    /// `IngestPreset` persists the templates. A preset saved before the year
    /// level existed must decode as "year folder on" — the behaviour it was
    /// saved under — rather than silently switching a library's layout.
    func testAPresetSavedBeforeTheYearOptionDecodesAsYearOn() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","primaryDestination":"/lib",
         "archiveDestination":"","folderTemplate":"{yyyy-MM-dd}","fileTemplate":"{OriginalStem}",
         "verifyCopies":true,"ejectAfterIngest":false}
        """
        let preset = try JSONDecoder().decode(IngestPreset.self, from: Data(json.utf8))
        XCTAssertTrue(preset.yearFolder, "an older preset must keep the layout it was saved with")
    }

    func testAPresetRoundTripsTheYearChoice() throws {
        let preset = IngestPreset(name: "Flat", primaryDestination: "/lib", archiveDestination: "",
                                  folderTemplate: "{yyyy-MM-dd}", fileTemplate: "{OriginalStem}",
                                  verifyCopies: true, ejectAfterIngest: false, yearFolder: false)
        let decoded = try JSONDecoder().decode(IngestPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertFalse(decoded.yearFolder)
    }
}
