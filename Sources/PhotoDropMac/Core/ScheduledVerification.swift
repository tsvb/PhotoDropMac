import Foundation

/// How often the background verification runs (always at 03:00 local).
enum VerifySchedule: String, CaseIterable, Sendable, Identifiable {
    case daily, weekly, monthly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    /// launchd `StartCalendarInterval` keys.
    var calendarInterval: [String: Int] {
        switch self {
        case .daily:   return ["Hour": 3, "Minute": 0]
        case .weekly:  return ["Weekday": 1, "Hour": 3, "Minute": 0]   // Sunday
        case .monthly: return ["Day": 1, "Hour": 3, "Minute": 0]       // 1st of the month
        }
    }
}

struct ScheduledVerificationError: Error, Sendable { let message: String }

/// Installs a `launchd` user agent that periodically runs `photodrop verify`
/// against a library and posts a notification if it finds issues. Report-only —
/// the scheduled job never heals or writes to the library (consistent with the
/// tool's conservative posture). Feasible because the app is unsandboxed; a
/// sandboxed build couldn't manage `LaunchAgents`.
enum ScheduledVerification {
    static let label = "com.tsvb.photodrop.verify"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var defaultLogPath: String {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs/PhotoDrop/scheduled-verify.log").path
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// The launchd job as a property-list dictionary. Pure → unit-testable. The
    /// command runs `photodrop verify --json` and, on a non-zero exit (issues
    /// found), posts a Notification Center banner via `osascript` — a launchd
    /// agent can't use `UNUserNotificationCenter` directly.
    static func jobPlist(photodropPath: String, libraryPath: String,
                         schedule: VerifySchedule, logPath: String) -> [String: Any] {
        let command = "\(quote(photodropPath)) verify \(quote(libraryPath)) --json"
            + " || /usr/bin/osascript -e 'display notification \"Verification found issues — see the PhotoDrop log.\" with title \"PhotoDrop\"'"
        return [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", command],
            "StartCalendarInterval": schedule.calendarInterval,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "RunAtLoad": false,
            "ProcessType": "Background",
        ]
    }

    static func plistData(photodropPath: String, libraryPath: String,
                          schedule: VerifySchedule, logPath: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: jobPlist(photodropPath: photodropPath, libraryPath: libraryPath,
                                       schedule: schedule, logPath: logPath),
            format: .xml, options: 0)
    }

    /// Write the agent plist and (re)load it via launchctl.
    static func install(photodropPath: String, libraryPath: String,
                        schedule: VerifySchedule, logPath: String = defaultLogPath) throws {
        let data = try plistData(photodropPath: photodropPath, libraryPath: libraryPath,
                                 schedule: schedule, logPath: logPath)
        let fm = FileManager.default
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: logPath).deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)

        let domain = "gui/\(getuid())"
        _ = try? runLaunchctl(["bootout", "\(domain)/\(label)"])   // remove any prior instance
        try runLaunchctl(["bootstrap", domain, plistURL.path])
    }

    static func uninstall() throws {
        _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(data: (try? errPipe.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ScheduledVerificationError(message: text.isEmpty
                ? "launchctl \(arguments.first ?? "") exited \(process.terminationStatus)"
                : text)
        }
        return process.terminationStatus
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
