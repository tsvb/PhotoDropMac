import XCTest
@testable import PhotoDropMac

/// "Couldn't read the card" must never be reported as "the card is empty".
///
/// **Threat model.** The scan result is what every downstream claim rests on: the
/// file count beside the Ingest button, the manifest, the exit code a wrapper
/// script branches on, and — decisively — whether the card is ejected. A scan
/// that silently comes back short converts a hardware or permissions problem into
/// a confident, wrong statement about the user's photos.
///
/// **Measured before-state.** `AssetDiscovery.scan` returned `[]` for a
/// nonexistent, unmounted or unreadable root (nil enumerator → `return []`),
/// indistinguishable from a card with no photos. `photodrop ingest --from
/// /Volumes/CRAD` printed *No recognized photos found* and exited **0**. Within a
/// readable card, the enumerator had no error handler and per-file errors hit a
/// `try?`, so a directory returning EIO just produced fewer bundles: a 500-photo
/// card could plan 137 files, report "✓ Ingest complete", and write a manifest
/// attesting to the 137.
///
/// This is the same rule `XattrOutcome` already enforced on the verify side; the
/// ingest side was the sink that was missed.
final class ScanOutcomeTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanOutcomeTests-\(UUID().uuidString)", isDirectory: true)
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

    private func writePhoto(_ name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 512).write(to: dir.appendingPathComponent(name))
    }

    func testNonexistentSourceIsUnreadableNotEmpty() throws {
        let tmp = try freshTempDir()
        let missing = tmp.appendingPathComponent("no-such-card", isDirectory: true)
        guard case .unreadableSource = AssetDiscovery.scanOutcome(root: missing) else {
            return XCTFail("a path that does not exist must not report as a card with no photos")
        }
    }

    func testAFileInsteadOfAFolderIsUnreadable() throws {
        let tmp = try freshTempDir()
        let file = tmp.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)
        guard case .unreadableSource = AssetDiscovery.scanOutcome(root: file) else {
            return XCTFail("a regular file is not a scannable source")
        }
    }

    func testUnreadableSourceIsUnreadable() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses the permission bits this test relies on")
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try writePhoto("IMG_0001.JPG", in: card)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: card.path)

        guard case .unreadableSource = AssetDiscovery.scanOutcome(root: card) else {
            return XCTFail("a card we cannot open must not report as a card with no photos")
        }
    }

    func testGenuinelyEmptyCardIsAScanNotAFailure() throws {
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)

        guard case let .scanned(bundles, unreadable, _) = AssetDiscovery.scanOutcome(root: card) else {
            return XCTFail("a readable empty folder is a successful scan of nothing")
        }
        XCTAssertTrue(bundles.isEmpty)
        XCTAssertEqual(unreadable, 0)
    }

    /// The partial case: the card opens, one subtree does not.
    func testUnreadableSubdirectoryIsCountedNotSwallowed() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses the permission bits this test relies on")
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try writePhoto("IMG_0001.JPG", in: card.appendingPathComponent("DCIM100", isDirectory: true))
        let locked = card.appendingPathComponent("DCIM101", isDirectory: true)
        try writePhoto("IMG_0002.JPG", in: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        guard case let .scanned(bundles, unreadable, _) = AssetDiscovery.scanOutcome(root: card) else {
            return XCTFail("the card itself is readable, so this is a partial scan, not a failure")
        }
        XCTAssertEqual(bundles.count, 1, "only the readable folder's photo was found")
        XCTAssertGreaterThan(unreadable, 0, "and the walk has to say that it missed something")

        let outcome = AssetDiscovery.scanOutcome(root: card)
        XCTAssertFalse(outcome.isComplete, "isComplete is what gates the auto-eject")
    }

    /// `scan` keeps its old shape for callers that don't branch on the failure —
    /// it must stay a plain list, so the change is additive.
    func testScanStillReturnsBundlesForExistingCallers() throws {
        let tmp = try freshTempDir()
        let card = tmp.appendingPathComponent("card", isDirectory: true)
        try writePhoto("IMG_0001.JPG", in: card)
        XCTAssertEqual(AssetDiscovery.scan(root: card).count, 1)
        XCTAssertTrue(AssetDiscovery.scan(root: tmp.appendingPathComponent("nope")).isEmpty)
    }
}
