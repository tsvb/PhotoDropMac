import XCTest
@testable import PhotoDropMac

/// S-9 — the CLI's security-relevant behavior had no tests at all, because the
/// test target cannot see `Sources/PhotoDropCLI` (`project.yml`: the tool target
/// owns those sources outright).
///
/// Two things were therefore unpinned. The **exit codes** — `ScheduledVerification`
/// branches on 0 / 1 / 2 to decide which alarm to raise, and the whole reason
/// those were split is that one alarm for both "found issues" and "no manifest"
/// trains a user to ignore the nightly notification. And **`CLIOutput.safe`**,
/// the guard that keeps card-authored text from driving the terminal; its rule
/// now lives in `SafeText` (covered by `UntrustedTextSinkTests`), but a unit test
/// can pass over a guard that is no longer *called* — S-4 is the cautionary tale,
/// a Tier-2 fix that was entirely inert in production with its unit tests green.
///
/// So these drive the real binary embedded in the host app and assert on what it
/// actually emitted. Nothing here runs `ingest`: that writes to the user's real
/// `~/Library/Logs/PhotoDrop`, and the suite is hermetic.
final class CLIBlackBoxTests: XCTestCase {

    private var cli: URL!
    private var tmp: URL!

    override func setUpWithError() throws {
        // The suite is hosted, so `Bundle.main` is the app — which embeds the
        // tool at `Contents/MacOS/photodrop`. Resolving it through `EmbeddedCLI`
        // means this also fails loudly if the embed dependency ever drops out of
        // `project.yml`, which would silently disarm scheduled verification.
        cli = try XCTUnwrap(EmbeddedCLI.url,
            "the app bundle must embed photodrop — see project.yml's embed dependency")
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBlackBox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { [tmp] in try? FileManager.default.removeItem(at: tmp!) }
    }

    private func run(_ arguments: [String]) async throws -> ChildProcess.Output {
        try await ChildProcess.run(executable: cli, arguments: arguments, timeout: 60)
    }

    /// A one-file library whose manifest is honest.
    @discardableResult
    private func makeLibrary(named name: String, fileName: String = "IMG_0001.CR2") throws -> URL {
        let library = tmp.appendingPathComponent(name, isDirectory: true)
        let day = library.appendingPathComponent("2026/2026-05-28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent(fileName)
        try Data("photo bytes".utf8).write(to: file)
        let digest = try XxHash64.hash(fileAt: file)

        let manifest = Manifest(
            schema: Manifest.schemaID, app: Manifest.appName,
            createdAt: Date(timeIntervalSince1970: 1_716_000_000), source: nil,
            primaryDestination: library.path(percentEncoded: false),
            archiveDestination: nil,
            destinations: [library.path(percentEncoded: false)],
            verified: true, partial: false, filesCopied: 1, filesSkipped: 0, filesFailed: 0,
            totalBytes: 11, elapsedSeconds: 0,
            files: [ManifestEntry(name: fileName, path: "2026/2026-05-28/\(fileName)",
                                  bytes: 11, xxhash64: String(format: "%016llx", digest),
                                  status: "verified")])
        XCTAssertNotNil(ManifestWriter.write(manifest, intoRoot: library,
                                             stamp: Date(timeIntervalSince1970: 1_716_000_000)))
        return library
    }

    // MARK: - The exit codes the launchd agent branches on

    func testVerifyExitsZeroOnAVerifiedLibrary() async throws {
        let library = try makeLibrary(named: "clean")
        let out = try await run(["verify", library.path])
        XCTAssertEqual(out.status, 0, "stderr: \(out.stderrText)")
        XCTAssertTrue(out.stdoutText.contains("✓"), out.stdoutText)
    }

    func testVerifyExitsOneWhenAFileChanged() async throws {
        let library = try makeLibrary(named: "damaged")
        try Data("tampered".utf8)
            .write(to: library.appendingPathComponent("2026/2026-05-28/IMG_0001.CR2"))
        let out = try await run(["verify", library.path])
        XCTAssertEqual(out.status, 1, "silent corruption must be exit 1 — stdout: \(out.stdoutText)")
    }

    /// Exit 2 is "could not check", which the nightly agent reports differently
    /// from "found issues". Collapsing the two is what made it cry wolf.
    func testVerifyExitsTwoWithNoManifest() async throws {
        let empty = tmp.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let out = try await run(["verify", empty.path])
        XCTAssertEqual(out.status, 2)
        XCTAssertTrue(out.stderrText.contains("No verification manifest found"), out.stderrText)
    }

    func testVerifyExitsTwoOnAPathThatDoesNotExist() async throws {
        let out = try await run(["verify", tmp.appendingPathComponent("typo").path])
        XCTAssertEqual(out.status, 2, "a typo'd path must never read as 'all verified'")
    }

    /// ArgumentParser's `EX_USAGE`. The tool never chooses it, but anything
    /// branching on `$?` sees it, so it is part of the contract.
    func testUnknownFlagIsAUsageError() async throws {
        let library = try makeLibrary(named: "usage")
        let out = try await run(["verify", library.path, "--not-a-flag"])
        XCTAssertEqual(out.status, 64)
    }

    func testHealExitsZeroWhenHealthyAndOneWhenDamaged() async throws {
        let healthy = try makeLibrary(named: "heal-clean")
        let healthyRun = try await run(["heal", healthy.path])
        XCTAssertEqual(healthyRun.status, 0, healthyRun.stderrText)

        let damaged = try makeLibrary(named: "heal-damaged")
        try FileManager.default.removeItem(at: damaged.appendingPathComponent("2026/2026-05-28/IMG_0001.CR2"))
        let damagedRun = try await run(["heal", damaged.path])
        XCTAssertEqual(damagedRun.status, 1, damagedRun.stderrText)
    }

    // MARK: - JSON shape

    func testVerifyJSONHasTheFieldsAConsumerBranchesOn() async throws {
        let library = try makeLibrary(named: "json")
        let out = try await run(["verify", library.path, "--json"])
        XCTAssertEqual(out.status, 0)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: out.stdout) as? [String: Any],
            "not a JSON object: \(out.stdoutText)")
        for key in ["verified", "total", "allGood", "issues"] {
            XCTAssertNotNil(object[key], "missing `\(key)` — the JSON report is a public contract")
        }
        XCTAssertEqual(object["allGood"] as? Bool, true)
    }

    // MARK: - The terminal guard, at execution level

    /// A card filename can carry an ESC. The CLI writes its own progress line
    /// with `\r\u{1B}[K`, so the terminal is honouring escapes: an unescaped one
    /// in a reported path can blank or rewrite the verdict line — which for a
    /// verification tool means forging its answer. Asserted on the bytes the
    /// process actually wrote, not on a helper's return value.
    func testHostileFilenamesNeverReachTheTerminalRaw() async throws {
        let library = try makeLibrary(named: "hostile", fileName: "IMG\u{1B}[2K\u{202E}0001.CR2")
        try FileManager.default.removeItem(
            at: library.appendingPathComponent("2026/2026-05-28/IMG\u{1B}[2K\u{202E}0001.CR2"))

        let out = try await run(["verify", library.path])
        XCTAssertEqual(out.status, 1)
        let text = out.stdoutText + out.stderrText
        XCTAssertFalse(text.unicodeScalars.contains("\u{1B}"), "a raw ESC reached the terminal")
        XCTAssertFalse(text.unicodeScalars.contains("\u{202E}"), "a raw bidi override reached the terminal")
        XCTAssertTrue(text.contains("\\x1B"), "…and the escape is still shown to the user: \(text)")
    }

    // MARK: - sync

    /// `sync` writes to a mirror on the strength of a manifest, so its exit codes
    /// are part of the same contract as `verify`'s: 0 up to date, 1 issues
    /// (a conflict it refused to overwrite), 2 could not run. Also asserted: the
    /// mirror is verifiable afterwards, and the user is told that `heal` will
    /// not search this mirror unaided.
    func testSyncExitCodesAndTheHealHint() async throws {
        let library = try makeLibrary(named: "sync-library")
        let mirror = tmp.appendingPathComponent("sync-mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)

        let synced = try await run(["sync", library.path, "--to", mirror.path])
        XCTAssertEqual(synced.status, 0, synced.stderrText)
        XCTAssertTrue(synced.stdoutText.contains("✓"), synced.stdoutText)
        XCTAssertTrue(synced.stdoutText.contains("--mirror"),
                      "the library never recorded this mirror; heal needs to be told: \(synced.stdoutText)")
        let verified = try await run(["verify", mirror.path])
        XCTAssertEqual(verified.status, 0, "a synced mirror must verify on its own: \(verified.stderrText)")

        let conflicting = tmp.appendingPathComponent("sync-conflict", isDirectory: true)
        try FileManager.default.createDirectory(at: conflicting.appendingPathComponent("2026/2026-05-28"),
                                                withIntermediateDirectories: true)
        try Data("not the same bytes".utf8)
            .write(to: conflicting.appendingPathComponent("2026/2026-05-28/IMG_0001.CR2"))
        let conflict = try await run(["sync", library.path, "--to", conflicting.path])
        XCTAssertEqual(conflict.status, 1, conflict.stdoutText)
        XCTAssertTrue(conflict.stdoutText.contains("CONFLICT"), conflict.stdoutText)
        XCTAssertEqual(String(data: try Data(contentsOf: conflicting.appendingPathComponent("2026/2026-05-28/IMG_0001.CR2")),
                              encoding: .utf8), "not the same bytes", "never overwritten")

        let missing = try await run(["sync", library.path, "--to", tmp.appendingPathComponent("no-such-mirror").path])
        XCTAssertEqual(missing.status, 2, "a mirror that does not exist must not be created")
    }
}
