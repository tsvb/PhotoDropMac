import XCTest
@testable import PhotoDropMac

/// Regressions for the Tier C findings — the lower-severity ones recorded in
/// `REVIEW.md` after the third review pass. None of them lose a file; each makes
/// the app do something quietly wrong, slow, or unverifiable.
final class TierCTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TierCTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ name: String, in dir: URL, bytes: Int = 64) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: bytes).write(to: dir.appendingPathComponent(name))
    }

    // MARK: - C3 · companion matching

    /// **Measured before-state.** `classifyCompanion` matched by
    /// `hasPrefix(primaryStem + ".")`, so `IMG_1234.v2.xmp` classified as a
    /// short-form sidecar of `IMG_1234.CR2`. `CopyPlan` renames a short-form
    /// sidecar to `{newStem}.xmp` — byte-identical to what the real
    /// `IMG_1234.xmp` gets — so the two planned onto one path.
    func testASuffixedSidecarIsNotACompanion() throws {
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try write("IMG_1234.CR2", in: card)
        try write("IMG_1234.xmp", in: card)
        try write("IMG_1234.v2.xmp", in: card)

        let bundles = AssetDiscovery.scan(root: card)
        XCTAssertEqual(bundles.count, 1)
        let names = bundles[0].companions.map(\.url.lastPathComponent).sorted()
        XCTAssertEqual(names, ["IMG_1234.xmp"],
                       "only the exact-stem sidecar belongs to this primary, got \(names)")
    }

    /// The long form still works — the exactness must not break `IMG.DNG.xmp`.
    func testLongFormSidecarStillMatches() throws {
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try write("IMG_1234.DNG", in: card)
        try write("IMG_1234.DNG.xmp", in: card)
        try write("IMG_1234.dng.dop", in: card)   // case-insensitive, as documented

        let bundles = AssetDiscovery.scan(root: card)
        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(Set(bundles[0].companions.map(\.kind)), [.xmp, .dop])
    }

    /// **Measured before-state.** `buildBundle` re-scanned all siblings and never
    /// consulted `consumed`, so with DNG Converter output — `IMG_1234.CR2`,
    /// `IMG_1234.DNG`, `IMG_1234.xmp` side by side — the xmp joined *both*
    /// bundles. The second bundle then collided with the first on the sidecar's
    /// destination and was pushed to `_1` even though nothing about the DNG
    /// collided, and the same sidecar was copied, hashed and manifested twice.
    func testASidecarBelongsToExactlyOnePrimary() throws {
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try write("IMG_1234.CR2", in: card)
        try write("IMG_1234.DNG", in: card)
        try write("IMG_1234.xmp", in: card)

        let bundles = AssetDiscovery.scan(root: card)
        XCTAssertEqual(bundles.count, 2, "both RAWs are primaries; neither is the other's companion")

        let claims = bundles.flatMap { $0.companions.map(\.url) }
        XCTAssertEqual(claims.count, Set(claims).count, "a companion was claimed twice: \(claims)")
        XCTAssertEqual(claims.map(\.lastPathComponent), ["IMG_1234.xmp"])
    }

    /// Which primary wins must not depend on enumerator order.
    func testTheClaimingPrimaryIsDeterministic() throws {
        for _ in 0..<5 {
            let tmp = try freshTempDir()
            let card = tmp.appendingPathComponent("card", isDirectory: true)
            try write("IMG_1234.CR2", in: card)
            try write("IMG_1234.DNG", in: card)
            try write("IMG_1234.xmp", in: card)

            let owner = AssetDiscovery.scan(root: card)
                .first { !$0.companions.isEmpty }?.primary.url.lastPathComponent
            XCTAssertEqual(owner, "IMG_1234.CR2", "sibling order decides, so it must be sorted")
        }
    }

    // MARK: - C2 · the date source is reported

    /// **Measured before-state.** `ScannedPhoto.dateSource` was set on every scan
    /// and `grep -rn dateSource Sources/` matched only the definition — no UI, no
    /// log line, no manifest field. It is the one signal that tells a user a photo
    /// was filed by file date rather than by the camera's clock, which is exactly
    /// the case most likely to put it in the wrong day folder (a card copied
    /// through another machine carries that machine's mtime).
    func testTheIngestLogSaysHowManyPhotosLackACaptureDate() async throws {
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let library = tmp.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 28; c.hour = 12
        let date = Calendar.current.date(from: c)!
        var bundles: [AssetBundle] = []
        for (i, source) in [ScannedPhoto.DateSource.exif, .fileModification, .fileModification].enumerated() {
            let url = card.appendingPathComponent("IMG_000\(i).JPG")
            try Data(repeating: UInt8(i + 1), count: 512).write(to: url)
            bundles.append(AssetBundle(
                primary: ScannedPhoto(id: url, url: url, size: 512, dateTaken: date, dateSource: source),
                companions: []))
        }

        final class Sink: @unchecked Sendable { var lines: [String] = [] }
        let sink = Sink()
        let engine = IngestEngine(
            bundles: bundles, description: "", primaryRoot: library, archiveRoots: [],
            verify: true, ejectAfter: false, sourceMountPoint: nil, sourceVolumeID: "v",
            template: .default, cardLabel: "",
            cache: HashCache(storeURL: tmp.appendingPathComponent("cache.json")),
            indexStoreURL: tmp.appendingPathComponent("index.json"),
            logDirectory: tmp.appendingPathComponent("Logs", isDirectory: true),
            onLog: { sink.lines.append($0.line) })
        _ = await engine.run()

        XCTAssertTrue(sink.lines.contains { $0.contains("2 of 3") && $0.contains("filed by file date") },
                      "the fallback-dated count has to reach the log: \(sink.lines)")
    }

    /// …and stays quiet when every photo has a real capture date, so the line
    /// means something when it does appear.
    func testNoDateSourceNoticeWhenEveryPhotoHasExif() async throws {
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let library = tmp.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 28; c.hour = 12
        let url = card.appendingPathComponent("IMG_0001.JPG")
        try Data(repeating: 0x11, count: 512).write(to: url)
        let bundle = AssetBundle(
            primary: ScannedPhoto(id: url, url: url, size: 512,
                                  dateTaken: Calendar.current.date(from: c)!, dateSource: .exif),
            companions: [])

        final class Sink: @unchecked Sendable { var lines: [String] = [] }
        let sink = Sink()
        let engine = IngestEngine(
            bundles: [bundle], description: "", primaryRoot: library, archiveRoots: [],
            verify: true, ejectAfter: false, sourceMountPoint: nil, sourceVolumeID: "v",
            template: .default, cardLabel: "",
            cache: HashCache(storeURL: tmp.appendingPathComponent("cache.json")),
            indexStoreURL: tmp.appendingPathComponent("index.json"),
            logDirectory: tmp.appendingPathComponent("Logs", isDirectory: true),
            onLog: { sink.lines.append($0.line) })
        _ = await engine.run()

        XCTAssertFalse(sink.lines.contains { $0.contains("filed by file date") }, "\(sink.lines)")
    }

    // MARK: - C9 · planning

    /// **Measured before-state.** `plan` restarted its disambiguator search at
    /// n = 0 for every bundle, so with a filename template that has no per-file
    /// component the work was quadratic: 800 bundles rendering to one name took
    /// 1.95 s. The names are still correct — this pins that the *hint* doesn't
    /// change them, and that it actually bounds the work.
    func testMassCollisionPlanningIsLinearAndStillCorrect() {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 28; c.hour = 12; c.minute = 0; c.second = 0
        let date = Calendar.current.date(from: c)!
        let card = URL(fileURLWithPath: "/card", isDirectory: true)

        let bundles = (1...400).map { i -> AssetBundle in
            let url = card.appendingPathComponent(String(format: "IMG_%04d.JPG", i))
            return AssetBundle(
                primary: ScannedPhoto(id: url, url: url, size: 100, dateTaken: date, dateSource: .exif),
                companions: [])
        }
        // No per-file token: every bundle renders to the same base name.
        let template = NamingTemplate(folder: "{yyyy-MM-dd}", filename: "{yyyyMMdd_HHmmss}")

        let started = Date()
        let plans = CopyPlan.planBatch(bundles: bundles, destinationRoot: URL(fileURLWithPath: "/dest"),
                                       description: "", template: template, cardLabel: "")
        let elapsed = Date().timeIntervalSince(started)

        let paths = plans.flatMap { $0.files.map(\.destination.path) }
        XCTAssertEqual(Set(paths.map(CopyPlan.collisionKey)).count, 400, "every file still gets its own path")
        XCTAssertLessThan(elapsed, 1.0, "400 colliding bundles took \(elapsed)s — the hint isn't bounding the search")
    }

    /// The hint keys on the base *name*, not the folder: distinct names in one
    /// day-folder must not inherit each other's suffixes.
    func testDistinctNamesInOneFolderStaySuffixFree() {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 28; c.hour = 12
        let date = Calendar.current.date(from: c)!
        let card = URL(fileURLWithPath: "/card", isDirectory: true)

        let bundles = (1...20).map { i -> AssetBundle in
            let url = card.appendingPathComponent(String(format: "IMG_%04d.JPG", i))
            return AssetBundle(
                primary: ScannedPhoto(id: url, url: url, size: 100, dateTaken: date, dateSource: .exif),
                companions: [])
        }
        let plans = CopyPlan.planBatch(bundles: bundles, destinationRoot: URL(fileURLWithPath: "/dest"),
                                       description: "", template: .default, cardLabel: "")
        for path in plans.flatMap({ $0.files.map(\.destination.path) }) {
            XCTAssertFalse(path.contains("_1."), "gratuitous disambiguator in \(path)")
        }
    }

    func testLacksPerFileTokenIdentifiesTemplatesThatCollide() {
        XCTAssertTrue(TemplateRenderer.lacksPerFileToken("{yyyy-MM-dd}"))
        XCTAssertTrue(TemplateRenderer.lacksPerFileToken("{yyyyMMdd_HHmmss}"))
        XCTAssertFalse(TemplateRenderer.lacksPerFileToken(NamingTemplate.default.filename))
        XCTAssertFalse(TemplateRenderer.lacksPerFileToken("{OriginalName}"))
    }

    // MARK: - C5 · HashCache

    /// **Measured before-state.** `HashCache.init` did `Data(contentsOf:)` plus a
    /// full `JSONDecoder` pass, and an actor's init body runs synchronously on
    /// the caller — which for `Copier.init` is the main actor, re-run at every
    /// window open. Construction must now touch no disk at all.
    func testConstructionDoesNoIO() throws {
        let tmp = try freshTempDir()
        let store = tmp.appendingPathComponent("cache.json")
        // A store that would *fail* to decode if it were read eagerly, and whose
        // access time we can observe.
        try Data("not json".utf8).write(to: store)
        let before = try FileManager.default.attributesOfItem(atPath: store.path)[.modificationDate] as? Date

        _ = HashCache(storeURL: store)   // must not read

        let after = try FileManager.default.attributesOfItem(atPath: store.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    /// A corrupt store still fails closed, now on first use rather than in init.
    func testCorruptStoreYieldsAnEmptyCacheNotAWrongOne() async throws {
        let tmp = try freshTempDir()
        let store = tmp.appendingPathComponent("cache.json")
        try Data("{ this is not json".utf8).write(to: store)
        let file = tmp.appendingPathComponent("f.bin")
        try Data(repeating: 0x7, count: 128).write(to: file)

        let cache = HashCache(storeURL: store)
        let hash = await cache.destinationHash(url: file)
        XCTAssertEqual(hash, try XxHash64.hash(fileAt: file, bypassCache: true),
                       "a corrupt store must mean 'no cache', never a wrong digest")
    }

    /// Entries survive a save/load round-trip through the lazy load.
    func testEntriesRoundTripThroughTheLazyLoad() async throws {
        let tmp = try freshTempDir()
        let store = tmp.appendingPathComponent("cache.json")
        let file = tmp.appendingPathComponent("f.bin")
        try Data(repeating: 0x9, count: 256).write(to: file)
        let expected = try XxHash64.hash(fileAt: file, bypassCache: true)

        let writer = HashCache(storeURL: store)
        await writer.recordDestination(url: file, hash: expected)
        try await writer.save()

        let reader = HashCache(storeURL: store)
        let loaded = await reader.destinationHash(url: file)
        XCTAssertEqual(loaded, expected)
    }

    // MARK: - C10 · EmbeddedCLI

    /// **Threat model.** This path is `MaintenancePreferences`' default for the
    /// launchd plist, so a wrong or missing one is a nightly verification that
    /// silently never runs — and the whole point of that job is to tell you when
    /// something is wrong.
    ///
    /// **Measured before-state.** The primary branch returned
    /// `Bundle.main.url(forAuxiliaryExecutable:)` unchecked, which is a
    /// constructed path, not an existence claim — unlike the fallback branch,
    /// which did check `isExecutableFile`.
    ///
    /// **And then CI proved the API itself unusable.** On macOS 15 / Xcode 16.4
    /// — inside the deployment range — `url(forAuxiliaryExecutable:)` returned
    /// nil for a genuinely embedded bundle, so this test and
    /// `testTheTestHostBundleCarriesTheEmbeddedCLI` both failed there while
    /// passing on macOS 26. `resolve` now composes the candidate paths itself.
    /// This is the whole argument for running CI on an older toolchain.
    func testResolveRejectsAPathThatIsNotExecutable() throws {
        let tmp = try freshTempDir()
        let bundleURL = tmp.appendingPathComponent("Fake.app", isDirectory: true)
        let macOS = bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        // Present but not executable — the stripped-bundle case.
        let tool = macOS.appendingPathComponent("photodrop")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tool.path)

        let bundle = try XCTUnwrap(Bundle(url: bundleURL) ?? Bundle(path: bundleURL.path))
        XCTAssertNil(EmbeddedCLI.resolve(in: bundle), "a non-executable file is not a usable CLI")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        XCTAssertNotNil(EmbeddedCLI.resolve(in: bundle), "and an executable one is")
    }

    func testResolveFindsTheHelpersFallback() throws {
        let tmp = try freshTempDir()
        let bundleURL = tmp.appendingPathComponent("Fallback.app", isDirectory: true)
        let helpers = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let tool = helpers.appendingPathComponent("photodrop")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let bundle = try XCTUnwrap(Bundle(url: bundleURL) ?? Bundle(path: bundleURL.path))
        XCTAssertEqual(EmbeddedCLI.resolve(in: bundle)?.lastPathComponent, "photodrop")
    }

    /// The shipping app must actually carry the tool — `project.yml` embeds it,
    /// and this is the only thing that would notice if that stopped working.
    func testTheTestHostBundleCarriesTheEmbeddedCLI() throws {
        let host = try XCTUnwrap(Bundle(identifier: "com.tsvb.PhotoDropMac")
                                 ?? Bundle.allBundles.first { $0.bundlePath.hasSuffix("PhotoDropMac.app") })
        XCTAssertNotNil(EmbeddedCLI.resolve(in: host),
                        "the app bundle should embed photodrop at Contents/MacOS — see project.yml")
    }
}
