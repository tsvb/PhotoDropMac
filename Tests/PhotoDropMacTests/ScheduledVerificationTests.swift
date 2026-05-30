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
}
