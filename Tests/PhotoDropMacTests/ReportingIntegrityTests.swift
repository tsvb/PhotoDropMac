import XCTest
@testable import PhotoDropMac

/// The Tier B defects: places where the app produced a confident answer about
/// something it had not actually looked at, or quietly reinterpreted input.
///
/// These are grouped because they share one property — none of them lose a byte,
/// and all of them make the product (a trustworthy verdict) wrong.
final class ReportingIntegrityTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportingIntegrityTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - B1: an unreadable subtree is not a pass

    /// **Threat model.** `verify --xattr` is the only tool that can check a folder
    /// with no manifest, so its verdict is load-bearing.
    /// **Measured before-state.** The enumerator was created with no
    /// `errorHandler`, so a subtree it could not open was skipped in silence and
    /// the run printed `✓ All N files match` with exit 0 over a library a third of
    /// which was never opened.
    func testXattrWalkCountsDirectoriesItCouldNotRead() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses the permission bits this test relies on")
        let tmp = try freshTempDir()
        let good = tmp.appendingPathComponent("2024", isDirectory: true)
        let locked = tmp.appendingPathComponent("2023", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)

        let stamped = good.appendingPathComponent("a.dng")
        try Data(repeating: 0x01, count: 64).write(to: stamped)
        FileChecksumXattr.stamp(try XxHash64.hash(fileAt: stamped), on: stamped)

        try Data(repeating: 0x02, count: 64).write(to: locked.appendingPathComponent("b.dng"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        guard case let .report(report) = VerifyEngine.runXattr(folder: tmp) else {
            return XCTFail("the top-level folder is readable, so this is a report")
        }
        XCTAssertEqual(report.verified, 1)
        XCTAssertGreaterThan(report.unreadableDirectories, 0,
                             "a folder that could not be opened must appear in the verdict")
        XCTAssertFalse(report.allGood,
                       "a run that skipped part of the target is not a clean bill of health")
    }

    // MARK: - B2: unstamped files are counted, not dropped

    /// **Measured before-state.** Unstamped files were skipped with no tally, so a
    /// library that lost 9,000 of 10,000 xattrs — `cp -X`, a zip/unzip restore,
    /// some cloud sync — reported `✓ All 1,000 files match`.
    func testXattrWalkReportsFilesCarryingNoChecksum() throws {
        let tmp = try freshTempDir()
        let stamped = tmp.appendingPathComponent("stamped.dng")
        try Data(repeating: 0x01, count: 64).write(to: stamped)
        FileChecksumXattr.stamp(try XxHash64.hash(fileAt: stamped), on: stamped)
        for i in 1...3 {
            try Data(repeating: UInt8(i), count: 64).write(to: tmp.appendingPathComponent("bare\(i).dng"))
        }

        guard case let .report(report) = VerifyEngine.runXattr(folder: tmp) else {
            return XCTFail("expected a report")
        }
        XCTAssertEqual(report.verified, 1)
        XCTAssertEqual(report.unstamped, 3, "the files it did not check have to be counted")
        XCTAssertTrue(report.allGood,
                      "unstamped is not damage — an absent attribute means 'unstamped', never 'changed'")
        // The CLI prints this count on both the pass and the failure branch. That
        // formatting is still untested here: `CLIOutput` lives in the `photodrop`
        // target, which the test bundle does not link (HANDOFF S-9, open).
    }

    /// A tree full of files and *no* stamps at all — an exFAT or SMB mirror,
    /// where `setxattr` fails on every write. This printed "No checksummed
    /// (xattr) files found" and exited 0 over a mirror that could be entirely
    /// bit-rotted.
    func testAFullyUnstampedTreeIsNotReportedAsNothingToCheck() throws {
        let tmp = try freshTempDir()
        for i in 1...3 {
            try Data(repeating: UInt8(i), count: 64).write(to: tmp.appendingPathComponent("f\(i).dng"))
        }
        guard case let .report(report) = VerifyEngine.runXattr(folder: tmp) else {
            return XCTFail("expected a report")
        }
        XCTAssertEqual(report.total, 0)
        XCTAssertEqual(report.unstamped, 3,
                       "'nothing was checked' and 'there was nothing here' must be distinguishable")
    }

    // MARK: - B3: a read failure is not persisted as "empty"

    /// **Threat model.** The dedup index decides whether a photo is copied.
    /// **Measured before-state.** A directory that failed to list was stored as an
    /// *empty* snapshot carrying its real mtime (`stat` succeeds on an unreadable
    /// directory), so the mtime fast path matched forever: one transient EIO made
    /// a day-folder permanently invisible to dedup, and every later re-ingest of
    /// that card re-copied its photos as `_1` variants.
    func testUnreadableDirectoryIsNotSnapshotAsEmpty() async throws {
        try XCTSkipIf(getuid() == 0, "root bypasses the permission bits this test relies on")
        let tmp = try freshTempDir()
        let root = tmp.appendingPathComponent("lib", isDirectory: true)
        let day = root.appendingPathComponent("2026/2026-05-28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let photo = day.appendingPathComponent("IMG_0001.DNG")
        try Data(repeating: 0x42, count: 4096).write(to: photo)
        let store = tmp.appendingPathComponent("index.json")

        // Build once with the folder unreadable, then restore it. The second
        // build must re-list rather than trust a cached "this folder is empty".
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: day.path)
        _ = DestinationIndex.build(at: root, storeURL: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: day.path)

        let index = DestinationIndex.build(at: root, storeURL: store)
        let cache = HashCache(storeURL: tmp.appendingPathComponent("cache.json"))
        let duplicate = await index.findDuplicate(sourceSize: 4096, sourceVolumeID: "v",
                                                  sourceURL: photo, using: cache)
        XCTAssertNotNil(duplicate,
                        "the folder is readable now; a stale 'empty' snapshot would hide this file forever")
    }

    // MARK: - B4: an unknown token is a typo, not a date pattern

    /// **Measured before-state.** Every unrecognized token went straight to
    /// `DateFormatter`, which reserves most ASCII letters: `{Descripton}` (one
    /// missing `i`) rendered `14854052026`, `{Wedding}` → `5528`, `{Shoot}` → `07`.
    /// And `isNamedEmpty: false` was returned unconditionally, so a token that
    /// rendered empty left a bare separator instead of dropping its group.
    func testUnknownTokensRenderEmptyAndDropTheirGroup() {
        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 28
        let context = TemplateContext(date: Calendar.current.date(from: c)!,
                                      description: "", originalName: "IMG_0001.CR2",
                                      originalStem: "IMG_0001", cardLabel: "")

        XCTAssertEqual(TemplateRenderer.render("{Descripton}", context), "",
                       "a typo must not silently become a date component")
        XCTAssertEqual(TemplateRenderer.render("{Wedding}", context), "")
        XCTAssertEqual(TemplateRenderer.render("x[_{Camera}]", context), "x",
                       "an empty unknown token drops its optional group, not just its own text")
        XCTAssertEqual(TemplateRenderer.unknownTokens(in: "{yyyy-MM-dd}[_{Descripton}]"), ["Descripton"])
        XCTAssertTrue(TemplateRenderer.unknownTokens(in: "{yyyy-MM-dd}_{Description}").isEmpty)
    }

    /// Real date patterns keep working — the whitelist must not break the
    /// defaults or anything reasonable a user has already typed.
    func testDatePatternsStillRender() {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 28; c.hour = 16; c.minute = 26; c.second = 40
        let context = TemplateContext(date: Calendar.current.date(from: c)!,
                                      description: "Trip", originalName: "IMG_0001.CR2",
                                      originalStem: "IMG_0001", cardLabel: "CARD")

        XCTAssertEqual(TemplateRenderer.render("{yyyy-MM-dd}", context), "2026-05-28")
        XCTAssertEqual(TemplateRenderer.render("{yyyyMMdd_HHmmss}", context), "20260528_162640")
        XCTAssertEqual(TemplateRenderer.render("{yyyy-MM-dd}[_{Description}]", context), "2026-05-28_Trip")
        XCTAssertEqual(TemplateRenderer.render("{MMM}", context), "May")
        XCTAssertTrue(TemplateRenderer.isDatePattern("yyyy'at'MM"), "quoted literals are valid pattern syntax")
    }

    // MARK: - B5: the DST gap is a real hour of shooting

    /// **Measured before-state.** `DateFormatter.date(from:)` answers nil for a
    /// local time that does not exist. Camera clocks do not observe DST, so a
    /// camera left on standard time stamps the skipped hour for a full hour of
    /// shooting: `2026:03:08 02:30:00` in America/Los_Angeles returned nil, and
    /// every frame fell through to the file's mtime — the *copy* time if the card
    /// has ever passed through another machine.
    func testSpringForwardGapStillParses() throws {
        // 2026-03-08 02:00–02:59 does not exist in America/Los_Angeles.
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let parsed = try XCTUnwrap(ExifReader.parse("2026:03:08 02:30:00", timeZone: zone),
                                   "the hour skipped by spring-forward is still an hour of shooting")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let day = cal.dateComponents([.year, .month, .day], from: parsed)
        XCTAssertEqual(day.year, 2026)
        XCTAssertEqual(day.month, 3)
        XCTAssertEqual(day.day, 8, "it must file under the day the photographer shot it")
    }

    /// The fall-back ambiguous hour (one local time, two instants) was already
    /// fine and must stay fine — pinned so the DST fix can't regress it.
    func testFallBackAmbiguousHourRoundTrips() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let parsed = try XCTUnwrap(ExifReader.parse("2026:11:01 01:30:00", timeZone: zone))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 11, 1, 1, 30])
    }

    /// The strictness that was there before stays there.
    func testInvalidExifDatesAreStillRejected() {
        XCTAssertNil(ExifReader.parse("0000:00:00 00:00:00"), "cameras really emit this for an unset clock")
        XCTAssertNil(ExifReader.parse("2026:02:30 12:00:00"), "Calendar is lenient and would roll this into March")
        XCTAssertNil(ExifReader.parse("2026:13:01 12:00:00"))
        XCTAssertNil(ExifReader.parse("2026:05:28 24:00:00"))
        XCTAssertNil(ExifReader.parse("2026:05:28 12:60:00"))
        XCTAssertNil(ExifReader.parse("garbage"))
        XCTAssertNil(ExifReader.parse(""))
        XCTAssertNotNil(ExifReader.parse("2026:05:28 16:26:40"))
    }

    // MARK: - B6: names have to be writable at every destination

    /// **Threat model.** N-way mirroring writes the same relative path to every
    /// root, and mirrors live on the filesystems least tolerant of exotic names.
    /// **Measured before-state.** `sanitize` handled `/ \ :` only, so a description
    /// as ordinary as `Trip?` produced a folder APFS accepts and every SMB/exFAT
    /// mirror refuses at `mkdir` — surfacing as "mirror 2: 500 failures" with
    /// nothing saying why.
    func testSanitizeRemovesCharactersMirrorFilesystemsReject() {
        for bad in ["?", "*", "<", ">", "|", "\""] {
            let out = PathPlanner.sanitize("Trip\(bad)Two")
            XCTAssertFalse(out.contains(bad), "“\(bad)” survived sanitize as \(out)")
        }
        XCTAssertFalse(PathPlanner.sanitize("Day 1.").hasSuffix("."),
                       "a trailing dot is silently stripped by SMB, so the mirror gets a different name")
        XCTAssertEqual(PathPlanner.sanitize("Trip/Two"), "Trip-Two", "the original rule still holds")
        XCTAssertEqual(PathPlanner.sanitize("....hidden"), "hidden", "and so does the leading-dot rule")
        XCTAssertEqual(PathPlanner.sanitize("Beach Day"), "Beach_Day")
    }
}
