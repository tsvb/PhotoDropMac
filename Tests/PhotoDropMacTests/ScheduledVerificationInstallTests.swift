import XCTest
@testable import PhotoDropMac

/// T3-5's tail: `install` / `uninstall` / `isLoaded` — the only part of
/// scheduled verification that was never tested, because it writes to
/// `~/Library/LaunchAgents` and shells out to `/bin/launchctl`. Both are now
/// injected (`ScheduledVerification.Agent`), so the suite can exercise them
/// without touching the developer's login items.
///
/// **What is at stake.** The failure this covers is silent by construction: the
/// user believes a nightly verification is running, and it is not — or believes
/// it is off while launchd still has the job. Nothing in the app surfaces either
/// state, so a test is the only place it can be caught.
///
/// The launchctl stub records its argv and takes its exit status from a control
/// file, so each test can make one subcommand fail without affecting the others.
final class ScheduledVerificationInstallTests: XCTestCase {

    private var dir: URL!
    private var agent: ScheduledVerification.Agent!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchedInstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }

        let launchctl = dir.appendingPathComponent("launchctl")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(dir.path)/calls.txt'
        status_file='\(dir.path)/status-'"$1"
        if [ -f "$status_file" ]; then exit "$(cat "$status_file")"; fi
        exit 0
        """.write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)

        agent = ScheduledVerification.Agent(
            launchAgentsDirectory: dir.appendingPathComponent("LaunchAgents", isDirectory: true),
            launchctl: launchctl)
    }

    private func makeSubcommandFail(_ subcommand: String, status: Int32 = 1) throws {
        try "\(status)\n".write(to: dir.appendingPathComponent("status-\(subcommand)"),
                                atomically: true, encoding: .utf8)
    }

    private var launchctlCalls: [String] {
        (try? String(contentsOf: dir.appendingPathComponent("calls.txt"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    private func install() async throws {
        try await ScheduledVerification.install(
            photodropPath: "/usr/local/bin/photodrop",
            libraryPath: "/Volumes/Photos",
            schedule: .daily,
            logPath: dir.appendingPathComponent("verify.log").path,
            agent: agent)
    }

    // MARK: - install

    func testInstallWritesTheAgentAndLoadsIt() async throws {
        try await install()

        let plist = agent.plistURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
        let decoded = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plist), format: nil) as? [String: Any]
        XCTAssertEqual(decoded?["Label"] as? String, ScheduledVerification.label)

        // Any prior instance is booted out first, then the new one bootstrapped:
        // re-applying settings must replace the job, not stack a second one.
        XCTAssertEqual(launchctlCalls.count, 2)
        XCTAssertTrue(launchctlCalls[0].hasPrefix("bootout "), launchctlCalls[0])
        XCTAssertTrue(launchctlCalls[1].hasPrefix("bootstrap "), launchctlCalls[1])
        XCTAssertTrue(launchctlCalls[1].hasSuffix(plist.path))
    }

    /// The invariant. A failed `bootstrap` that left the plist behind meant the
    /// Settings toggle read *off* — the caller resets it on error — while launchd
    /// could still pick the orphan up at the next login and run verifications the
    /// user believed were disabled. Either it is installed and loaded, or nothing
    /// is left.
    func testAFailedBootstrapLeavesNothingBehind() async throws {
        try makeSubcommandFail("bootstrap")

        do {
            try await install()
            XCTFail("a failed bootstrap must surface as an error")
        } catch {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.plistURL.path),
                       "an orphaned plist is a job the user thinks is disabled")
    }

    /// `bootout` fails routinely — there is usually nothing loaded to remove —
    /// so it must not be treated as an install failure.
    func testAFailedBooToutDoesNotBlockTheInstall() async throws {
        try makeSubcommandFail("bootout", status: 3)
        try await install()
        XCTAssertTrue(FileManager.default.fileExists(atPath: agent.plistURL.path))
    }

    // MARK: - uninstall

    func testUninstallBootsOutAndRemovesThePlist() async throws {
        try await install()
        try await ScheduledVerification.uninstall(agent: agent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.plistURL.path))
        XCTAssertEqual(launchctlCalls.last?.hasPrefix("bootout "), true)
    }

    /// Turning it off has to actually turn it off. If launchctl fails the plist
    /// must still go, or the next login reloads a job the user disabled.
    func testUninstallRemovesThePlistEvenWhenLaunchctlFails() async throws {
        try await install()
        try makeSubcommandFail("bootout")
        try await ScheduledVerification.uninstall(agent: agent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.plistURL.path))
    }

    // MARK: - isLoaded

    /// `isLoaded` asks launchd; `hasPlist` stats a file. They answer different
    /// questions and the UI must use the first — a plist on disk that launchd
    /// does not have is precisely the state the bootstrap-rollback exists to
    /// prevent, and stat-ing cannot see it.
    func testIsLoadedAsksLaunchdRatherThanStattingThePlist() async throws {
        try await install()
        XCTAssertTrue(agent.hasPlist)

        try makeSubcommandFail("print")
        let loaded = await ScheduledVerification.isLoaded(agent: agent)
        XCTAssertFalse(loaded, "a plist on disk is not evidence that launchd has the job")
        XCTAssertEqual(launchctlCalls.last, "print gui/\(getuid())/\(ScheduledVerification.label)")
    }

    func testIsLoadedIsTrueWhenLaunchdHasTheJob() async throws {
        try await install()
        let loaded = await ScheduledVerification.isLoaded(agent: agent)
        XCTAssertTrue(loaded)
    }

    /// The shipping configuration still points at the real home — the injection
    /// is for tests, not a behaviour change.
    func testTheLiveAgentTargetsTheUsersLaunchAgentsFolder() {
        let live = ScheduledVerification.Agent.live
        XCTAssertEqual(live.plistURL.path,
                       FileManager.default.homeDirectoryForCurrentUser
                           .appendingPathComponent("Library/LaunchAgents/\(ScheduledVerification.label).plist").path)
        XCTAssertEqual(live.launchctl.path, "/bin/launchctl")
    }
}
