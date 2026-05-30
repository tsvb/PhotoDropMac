import XCTest
@testable import PhotoDropMac

/// Companion-matching and two-pass discovery (`AssetDiscovery.scan`). Each test
/// builds a real directory tree of (empty) files in a temp dir and asserts the
/// resulting bundles — RAW primaries pull their same-directory companions,
/// standalone JPEGs become their own bundles, orphan sidecars drop, and
/// matching is same-directory only.
final class AssetDiscoveryTests: XCTestCase {

    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @discardableResult
    private func touch(_ relPath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }

    private func bundle(named name: String, in bundles: [AssetBundle]) -> AssetBundle? {
        bundles.first { $0.primary.url.lastPathComponent == name }
    }

    private func kinds(_ b: AssetBundle?) -> Set<CompanionKind> {
        Set((b?.companions ?? []).map(\.kind))
    }

    func testRawPullsJpegPairAndSidecars() throws {
        let root = try freshTempDir()
        try touch("DCIM/IMG_0001.DNG", in: root)
        try touch("DCIM/IMG_0001.JPG", in: root)   // jpeg pair
        try touch("DCIM/IMG_0001.xmp", in: root)   // short-form sidecar
        try touch("DCIM/IMG_0001.dop", in: root)

        let bundles = AssetDiscovery.scan(root: root)
        XCTAssertEqual(bundles.count, 1, "the JPEG is a companion, not a second bundle")
        let b = bundle(named: "IMG_0001.DNG", in: bundles)
        XCTAssertEqual(kinds(b), [.jpegPair, .xmp, .dop])
        XCTAssertEqual(b?.fileCount, 4)
    }

    func testLongFormSidecarIsMatched() throws {
        let root = try freshTempDir()
        try touch("IMG_0002.DNG", in: root)
        try touch("IMG_0002.DNG.xmp", in: root)    // Adobe long form: <name>.xmp

        let bundles = AssetDiscovery.scan(root: root)
        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(kinds(bundle(named: "IMG_0002.DNG", in: bundles)), [.xmp])
    }

    func testStandaloneJpegBecomesItsOwnBundle() throws {
        let root = try freshTempDir()
        try touch("SNAP.JPG", in: root)            // no RAW alongside

        let bundles = AssetDiscovery.scan(root: root)
        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(bundles.first?.primary.url.lastPathComponent, "SNAP.JPG")
        XCTAssertTrue(bundles.first?.companions.isEmpty ?? false)
    }

    func testOrphanSidecarIsDropped() throws {
        let root = try freshTempDir()
        try touch("ORPHAN.xmp", in: root)          // sidecar with no primary

        XCTAssertTrue(AssetDiscovery.scan(root: root).isEmpty)
    }

    func testCompanionMatchingIsSameDirectoryOnly() throws {
        let root = try freshTempDir()
        try touch("a/IMG_0003.DNG", in: root)
        try touch("b/IMG_0003.JPG", in: root)      // same stem, different directory

        let bundles = AssetDiscovery.scan(root: root)
        XCTAssertEqual(bundles.count, 2, "cross-directory pairing is not a feature")
        XCTAssertTrue(bundle(named: "IMG_0003.DNG", in: bundles)?.companions.isEmpty ?? false)
        XCTAssertNotNil(bundle(named: "IMG_0003.JPG", in: bundles))
    }

    func testAudioNoteCompanion() throws {
        let root = try freshTempDir()
        try touch("CLIP.NEF", in: root)
        try touch("CLIP.WAV", in: root)            // camera audio memo

        XCTAssertEqual(kinds(bundle(named: "CLIP.NEF", in: AssetDiscovery.scan(root: root))), [.audioNote])
    }
}
