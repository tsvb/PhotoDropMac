import XCTest
@testable import PhotoDropMac

/// The update channel — the one outbound network connection in the app, and a
/// path by which code from the internet becomes code running on the user's Mac.
///
/// Three measured before-states are pinned here:
///
/// 1. **The Sparkle keys silently vanished from the built app.** They were first
///    declared as `INFOPLIST_KEY_SUFeedURL` / `INFOPLIST_KEY_SUPublicEDKey`
///    build settings. Xcode's `INFOPLIST_KEY_*` mechanism only covers the keys
///    it knows, so both were accepted without a warning and were **absent from
///    the built `Info.plist`** — verified with `plutil -p`. Sparkle reads them
///    out of the bundle, so the shipped result is an app that never checks for
///    updates, never installs a security fix, and never says a word about it.
///    `testTheShippedBundleCarriesAnHTTPSUpdateFeed` is the regression: it reads
///    the *built* plist, not the source of it.
/// 2. **An unconfigured build must stay silent.** PRIVACY.md promises the app
///    makes no connection the user did not ask for. A build from source has no
///    signing key, and the rule is that it therefore starts no updater at all —
///    rather than politely failing checks against a feed it could not verify.
/// 3. **An ingest outranks an update.** Sparkle's terminal act is to replace and
///    relaunch the running application; this app's job is a copy whose only safe
///    stopping point is a file boundary (the same reason Quit routes through
///    `TerminationPolicy` instead of `NSApp.terminate`).
@MainActor
final class SoftwareUpdateTests: XCTestCase {

    /// A syntactically valid Ed25519 public key: 32 bytes, base64. Not a real
    /// signing key and not the project's — the point is the shape.
    private static let wellFormedKey = Data(repeating: 0x2b, count: 32).base64EncodedString()

    // MARK: - What the shipped bundle says

    /// The app bundle, whether the suite is running hosted in the app (it is) or
    /// ever moves to a plain xctest process.
    private var appBundle: Bundle {
        Bundle(identifier: "com.tsvb.PhotoDropMac") ?? .main
    }

    func testTheShippedBundleCarriesAnHTTPSUpdateFeed() throws {
        let feed = appBundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let unwrapped = try XCTUnwrap(feed, """
            SUFeedURL is missing from the built Info.plist. Sparkle reads it from \
            the bundle, so this build would never check for updates and would \
            never report that it wasn't. This is exactly what INFOPLIST_KEY_ \
            build settings did — silently.
            """)
        let url = try XCTUnwrap(URL(string: unwrapped))
        XCTAssertEqual(url.scheme, "https", "an appcast over plain HTTP is a way to hand the user someone else's application")
    }

    /// The key is empty in a fresh checkout and filled in by
    /// `scripts/sparkle-keys.sh`, so this cannot demand a value — that would fail
    /// CI for everyone forever. What it *can* refuse is a value that is present
    /// but wrong, which is the failure that otherwise reads as "updates just
    /// never work": a truncated paste, a DSA key in the EdDSA slot, a stray
    /// newline. `scripts/release.sh` is what refuses to ship the empty case.
    func testTheShippedSigningKeyIsEitherAbsentOrAWellFormedEd25519Key() {
        let key = (appBundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard case .ready = UpdateConfiguration.read(feedURL: "https://example.com/appcast.xml", publicKey: key) else {
            return XCTFail("SUPublicEDKey is present but is not a 32-byte Ed25519 public key: \(key)")
        }
    }

    // MARK: - Reading the configuration

    func testAWellFormedFeedAndKeyIsReady() {
        let config = UpdateConfiguration.read(
            feedURL: "https://raw.githubusercontent.com/tsvb/PhotoDropMac/main/appcast.xml",
            publicKey: Self.wellFormedKey)
        XCTAssertEqual(config, .ready(feed: URL(string: "https://raw.githubusercontent.com/tsvb/PhotoDropMac/main/appcast.xml")!))
        XCTAssertTrue(config.isReady)
        XCTAssertNil(config.explanation, "a working channel has nothing to explain")
    }

    func testAFeedWithNoKeyIsRefused() {
        XCTAssertEqual(UpdateConfiguration.read(feedURL: "https://example.com/a.xml", publicKey: nil), .unsigned)
        XCTAssertEqual(UpdateConfiguration.read(feedURL: "https://example.com/a.xml", publicKey: "  "), .unsigned)
        XCTAssertNotNil(UpdateConfiguration.read(feedURL: "https://example.com/a.xml", publicKey: "").explanation,
                        "the user must be told why Check for Updates does nothing")
    }

    /// A key of the wrong length is the one that looks fine at a glance. 32 bytes
    /// is the whole of an Ed25519 public key; anything else in that slot is a
    /// mistake, and Sparkle's own report of it is a console line.
    func testAKeyOfTheWrongShapeIsRefused() {
        XCTAssertEqual(UpdateConfiguration.read(feedURL: "https://example.com/a.xml", publicKey: "not base64 at all!"), .malformedKey)
        XCTAssertEqual(UpdateConfiguration.read(feedURL: "https://example.com/a.xml",
                                                publicKey: Data(repeating: 0x2b, count: 31).base64EncodedString()),
                       .malformedKey, "one byte short is still not a key")
        XCTAssertEqual(UpdateConfiguration.read(feedURL: "https://example.com/a.xml",
                                                publicKey: Data(repeating: 0x2b, count: 64).base64EncodedString()),
                       .malformedKey, "a 64-byte value is the *private* key — never ship that")
    }

    func testANonHTTPSFeedIsRefused() {
        XCTAssertEqual(UpdateConfiguration.read(feedURL: "http://example.com/a.xml", publicKey: Self.wellFormedKey),
                       .insecureFeed("http://example.com/a.xml"))
        XCTAssertEqual(UpdateConfiguration.read(feedURL: "file:///tmp/a.xml", publicKey: Self.wellFormedKey),
                       .insecureFeed("file:///tmp/a.xml"))
    }

    func testNoFeedAtAllIsTheUnconfiguredCase() {
        XCTAssertEqual(UpdateConfiguration.read(feedURL: nil, publicKey: Self.wellFormedKey), .noFeed)
        XCTAssertEqual(UpdateConfiguration.read(feedURL: "   ", publicKey: Self.wellFormedKey), .noFeed)
    }

    // MARK: - An unconfigured build starts nothing

    /// The privacy promise, as a test: no key means no updater, which means no
    /// connection. `start()` has to be a no-op, not a failing check.
    func testAnUnconfiguredBuildStartsNoUpdater() throws {
        let updater = SoftwareUpdater(bundle: try bundle(feed: "https://example.com/appcast.xml", key: ""))
        XCTAssertEqual(updater.configuration, .unsigned)
        updater.start()
        XCTAssertFalse(updater.canCheckForUpdates, "an unconfigured build must never claim it can check")
        updater.checkForUpdates()   // must not crash, must not connect
        XCTAssertNil(updater.lastCheckDate)
    }

    func testConfigurationIsReadFromTheBundleItIsGiven() throws {
        let updater = SoftwareUpdater(bundle: try bundle(feed: "https://example.com/appcast.xml", key: Self.wellFormedKey))
        XCTAssertTrue(updater.configuration.isReady)
        // Deliberately not started: starting a *ready* updater would reach the
        // network from a unit test.
    }

    // MARK: - The running-job gate

    func testTheGateIsPureAndSaysWhy() {
        XCTAssertEqual(UpdateGate.decide(hasRunningJob: false), .allow)
        XCTAssertEqual(UpdateGate.decide(hasRunningJob: true), .holdUntilTheJobFinishes)
        XCTAssertNil(UpdateGate.allow.refusalReason)
        XCTAssertNotNil(UpdateGate.holdUntilTheJobFinishes.refusalReason,
                        "a refused check has to be explainable, or it reads as a broken button")
    }

    /// The wiring, not just the rule: the updater finds the running job through
    /// the same `JobRegistry` the app delegate uses for Quit. A gate that is
    /// correct in isolation and unwired is worth nothing.
    func testARunningIngestHoldsUpdatesOff() async throws {
        let dir = try freshDir()
        let registry = JobRegistry()
        let updater = SoftwareUpdater(bundle: try bundle(feed: "https://example.com/appcast.xml", key: Self.wellFormedKey))
        updater.registry = registry
        XCTAssertEqual(updater.gate, .allow, "no job, no reason to hold")

        let copier = Copier.hermetic(in: dir)
        copier.registry = registry
        copier.start(yearGroups: [try card(dir, files: 6)],
                     primaryDestination: dir.appendingPathComponent("lib", isDirectory: true),
                     archiveDestinations: [], description: "", verify: true, ejectAfter: false,
                     sourceMountPoint: nil, sourceVolumeID: "vol", template: .default, cardLabel: "CARD")
        XCTAssertEqual(updater.gate, .holdUntilTheJobFinishes,
                       "Sparkle's terminal act is to replace and relaunch the app — not during a copy")

        await copier.waitForCompletion()
        XCTAssertEqual(updater.gate, .allow, "the hold must lift, or the app never updates again")
    }

    // MARK: - Cadence

    /// Sparkle owns the stored interval, so the selected row is *derived* from it
    /// rather than stored beside it — the same reason `FolderLayout.matching`
    /// derives the selected layout from the templates. A second stored key is
    /// free to contradict the number that actually governs.
    func testCadenceIsDerivedFromWhateverIntervalSparkleHolds() {
        for cadence in UpdateCadence.allCases {
            XCTAssertEqual(UpdateCadence.closest(to: cadence.seconds), cadence)
        }
        XCTAssertEqual(UpdateCadence.closest(to: 3_600), .daily, "Sparkle's floor is an hour; nearest is daily")
        XCTAssertEqual(UpdateCadence.closest(to: 500_000), .weekly)
        XCTAssertEqual(UpdateCadence.closest(to: 90 * 86_400), .monthly)
    }

    // MARK: - Fixtures

    /// A real, loadable bundle with a chosen Info.plist, so `SoftwareUpdater` can
    /// be tested against configurations this build does not have.
    private func bundle(feed: String, key: String) throws -> Bundle {
        let dir = try freshDir().appendingPathComponent("Fixture.bundle", isDirectory: true)
        let contents = dir.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.tsvb.PhotoDropMac.updatefixture",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundlePackageType": "BNDL",
            "SUFeedURL": feed,
            "SUPublicEDKey": key,
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: dir))
    }

    private func freshDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoftwareUpdate-\(UUID().uuidString)", isDirectory: true)
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
}
