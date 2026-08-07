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
}
