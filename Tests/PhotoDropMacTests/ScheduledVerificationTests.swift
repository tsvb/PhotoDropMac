import XCTest
@testable import PhotoDropMac

/// The launchd job-plist generation for scheduled verification (pure; the
/// launchctl install/uninstall is side-effecting and not unit-tested).
final class ScheduledVerificationTests: XCTestCase {
    func testJobPlistContents() {
        let plist = ScheduledVerification.jobPlist(
            photodropPath: "/usr/local/bin/photodrop",
            libraryPath: "/Volumes/Photos",
            schedule: .weekly,
            logPath: "/tmp/sv.log")

        XCTAssertEqual(plist["Label"] as? String, ScheduledVerification.label)
        XCTAssertEqual(plist["StandardOutPath"] as? String, "/tmp/sv.log")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, false)

        let args = try? XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(args?.first, "/bin/sh")
        let command = args?.last ?? ""
        XCTAssertTrue(command.contains("verify"), command)
        XCTAssertTrue(command.contains("'/usr/local/bin/photodrop'"), command)
        XCTAssertTrue(command.contains("'/Volumes/Photos'"), command)
        XCTAssertTrue(command.contains("--json"), command)
        XCTAssertTrue(command.contains("osascript"), "issues should trigger a notification")

        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int],
                       ["Weekday": 1, "Hour": 3, "Minute": 0])
    }

    func testScheduleIntervals() {
        XCTAssertEqual(VerifySchedule.daily.calendarInterval, ["Hour": 3, "Minute": 0])
        XCTAssertEqual(VerifySchedule.weekly.calendarInterval, ["Weekday": 1, "Hour": 3, "Minute": 0])
        XCTAssertEqual(VerifySchedule.monthly.calendarInterval, ["Day": 1, "Hour": 3, "Minute": 0])
    }

    func testPlistDataIsValidPropertyList() throws {
        let data = try ScheduledVerification.plistData(
            photodropPath: "/bin/photodrop", libraryPath: "/lib", schedule: .daily, logPath: "/tmp/x.log")
        let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try XCTUnwrap(decoded as? [String: Any])
        XCTAssertEqual(dict["Label"] as? String, ScheduledVerification.label)
        XCTAssertNotNil(dict["ProgramArguments"] as? [String])
    }

    func testPathsAreShellQuoted() {
        // A path with a space must survive in the /bin/sh -c command.
        let plist = ScheduledVerification.jobPlist(
            photodropPath: "/bin/photodrop", libraryPath: "/Volumes/My Photos",
            schedule: .monthly, logPath: "/tmp/x.log")
        let command = (plist["ProgramArguments"] as? [String])?.last ?? ""
        XCTAssertTrue(command.contains("'/Volumes/My Photos'"), command)
    }

    // MARK: - Exit 1 and exit 2 are different events

    /// Regression: the command was `verify … || osascript "Verification found
    /// issues"`, which fired the same alarm for exit 2 — "no manifest found".
    /// Pointed at a library that had never been ingested into, the agent cried
    /// wolf every night, which is how a user learns to ignore the one
    /// notification that matters.
    func testCommandDistinguishesIssuesFromCouldNotVerify() throws {
        let plist = ScheduledVerification.jobPlist(
            photodropPath: "/usr/local/bin/photodrop", libraryPath: "/lib",
            schedule: .daily, logPath: "/tmp/v.log")
        let args = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        let command = try XCTUnwrap(args.last)

        XCTAssertTrue(command.contains("RC=$?"), "the exit code has to be captured to branch on it")
        XCTAssertTrue(command.contains("[ $RC -eq 0 ]"), "a clean run exits quietly")
        XCTAssertTrue(command.contains("[ $RC -eq 1 ]"), "exit 1 is the corruption case")
        XCTAssertTrue(command.contains("Verification found issues"))
        XCTAssertTrue(command.contains("no manifest found"),
                      "exit 2 must say it could not verify, not that it found damage")
        XCTAssertFalse(command.contains("--json ||"),
                       "the old unconditional `|| notify` must be gone")
    }

    /// Output is echoed only on failure, so the agent log accumulates
    /// diagnostics for problems rather than a JSON report every night forever.
    func testCleanRunWritesNothingToTheLog() throws {
        let plist = ScheduledVerification.jobPlist(
            photodropPath: "/usr/local/bin/photodrop", libraryPath: "/lib",
            schedule: .weekly, logPath: "/tmp/v.log")
        let command = try XCTUnwrap((plist["ProgramArguments"] as? [String])?.last)
        let exitLine = try XCTUnwrap(command.split(separator: "\n")
            .first { $0.contains("[ $RC -eq 0 ]") })
        XCTAssertTrue(exitLine.contains("exit 0"), "clean runs return before printing anything")
    }

    // MARK: - What osascript actually receives

    /// Regression, and the reason this suite executes the command instead of
    /// grepping it: the branches originally shared one `osascript` call
    /// interpolating `$MSG`. The AppleScript must be single-quoted for the
    /// shell, and the shell does not expand variables inside single quotes — so
    /// the banner would have read a literal `$MSG` every night. The old tests
    /// asserted both message strings appeared *somewhere in the command* and
    /// passed green over a feature that was inert in production.
    ///
    /// `osascript` is rewritten to `/bin/echo` so the branch can be run for
    /// real without posting a notification from the test suite.
    private func notificationText(forExitCode code: Int32) throws -> String {
        let stub = try stubPhotodrop(exiting: code)
        let plist = ScheduledVerification.jobPlist(
            photodropPath: stub.path, libraryPath: "/lib",
            schedule: .daily, logPath: "/dev/null")
        let command = try XCTUnwrap((plist["ProgramArguments"] as? [String])?.last)
            .replacingOccurrences(of: "/usr/bin/osascript", with: "/bin/echo")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// A stand-in for the CLI that exits with the code under test.
    private func stubPhotodrop(exiting code: Int32) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchedVerifyStub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("photodrop")
        try "#!/bin/sh\necho '{\"stub\":true}'\nexit \(code)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testExitOneNotifiesThatIssuesWereFound() throws {
        let text = try notificationText(forExitCode: 1)
        XCTAssertTrue(text.contains(ScheduledVerification.issuesMessage),
                      "osascript must receive the real message, got: \(text)")
        XCTAssertFalse(text.contains("$"), "no unexpanded shell variable may survive: \(text)")
    }

    func testExitTwoNotifiesThatItCouldNotVerify() throws {
        let text = try notificationText(forExitCode: 2)
        XCTAssertTrue(text.contains(ScheduledVerification.cannotVerifyMessage),
                      "exit 2 is a different event and says so, got: \(text)")
        XCTAssertFalse(text.contains(ScheduledVerification.issuesMessage),
                       "and must not claim damage was found")
    }

    func testCleanRunNotifiesNothingAtAll() throws {
        let text = try notificationText(forExitCode: 0)
        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "a healthy library must be silent, got: \(text)")
    }
}
