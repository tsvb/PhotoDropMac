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

    /// Where the agent lives and what loads it — injected so the install path
    /// can be tested.
    ///
    /// This is the last piece of the app that had no tests, and the reason was
    /// that exercising it meant writing into the developer's real
    /// `~/Library/LaunchAgents` and running the real `launchctl`. That is not a
    /// tidiness problem: the failures this code exists to prevent are *silent*
    /// — a user who believes a nightly verification is running when it is not,
    /// or believes it is off while launchd still holds the job — and a test is
    /// the only place either can be caught. Same pattern as `JobLogger`'s
    /// injected directory and `Copier.hermetic(in:)`.
    struct Agent: Sendable {
        var launchAgentsDirectory: URL
        var launchctl: URL

        static let live = Agent(
            launchAgentsDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            launchctl: URL(fileURLWithPath: "/bin/launchctl"))

        var plistURL: URL {
            launchAgentsDirectory.appendingPathComponent("\(ScheduledVerification.label).plist")
        }

        /// Whether the agent plist is on disk. **Not** the same question as "is
        /// the job loaded" — see `isLoaded` — and on its own it will happily
        /// report an orphaned plist as installed.
        var hasPlist: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    }

    static var plistURL: URL { Agent.live.plistURL }

    static var defaultLogPath: String {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs/PhotoDrop/scheduled-verify.log").path
    }

    static var hasPlist: Bool { Agent.live.hasPlist }

    /// Whether launchd actually has the job. A plist can exist without being
    /// loaded (a failed `bootstrap` used to leave exactly that behind), and a
    /// stat can't tell the difference — so the UI asks launchd.
    static func isLoaded(agent: Agent = .live) async -> Bool {
        let output = try? await ChildProcess.run(
            executable: agent.launchctl,
            arguments: ["print", "gui/\(getuid())/\(label)"])
        return output?.isSuccess == true
    }

    /// The launchd job as a property-list dictionary. Pure → unit-testable. The
    /// command runs `photodrop verify --json` and posts a Notification Center
    /// banner via `osascript` — a launchd agent can't use
    /// `UNUserNotificationCenter` directly.
    ///
    /// **Exit 1 and exit 2 are different events and say different things.** The
    /// command used to be `verify … || osascript "Verification found issues"`,
    /// which fired the same alarm for exit 2 — "no manifest found". Point the
    /// agent at a library that has never been ingested into and it cried wolf
    /// every single night, which is exactly how a user learns to ignore the one
    /// notification that matters.
    ///
    /// Output is only echoed on a non-zero exit, so the log accumulates
    /// diagnostics for problems instead of a JSON report per night forever.
    ///
    /// Each branch emits its own complete `osascript` call with the message
    /// **inline**. The obvious factoring — one shared call interpolating `$MSG`
    /// — is silently broken: the AppleScript has to be single-quoted for the
    /// shell, and the shell does not expand variables inside single quotes, so
    /// the banner reads a literal `$MSG`. Unit tests that only assert the
    /// message text appears somewhere in the command string pass over that
    /// happily; `notificationScripts` exists so a test can execute the branches
    /// and read what `osascript` would actually receive.
    static func jobPlist(photodropPath: String, libraryPath: String,
                         schedule: VerifySchedule, logPath: String) -> [String: Any] {
        let command = """
            OUT=$(\(quote(photodropPath)) verify \(quote(libraryPath)) --json 2>&1); RC=$?
            if [ $RC -eq 0 ]; then exit 0; fi
            printf '%s\\n' "$(date)" "$OUT"
            if [ $RC -eq 1 ]; then
              /usr/bin/osascript -e \(quote(appleScript(message: issuesMessage)))
            else
              /usr/bin/osascript -e \(quote(appleScript(message: cannotVerifyMessage)))
            fi
            """
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
    ///
    /// If `bootstrap` fails the plist is removed again before throwing. Leaving
    /// it behind meant the settings toggle read *off* (the caller resets it on
    /// error) while `hasPlist` read *on*, and launchd could pick the orphan up
    /// at the next login — running verifications the user believed were
    /// disabled. Either the agent is installed and loaded, or nothing is left.
    static func install(photodropPath: String, libraryPath: String,
                        schedule: VerifySchedule, logPath: String = defaultLogPath,
                        agent: Agent = .live) async throws {
        let data = try plistData(photodropPath: photodropPath, libraryPath: libraryPath,
                                 schedule: schedule, logPath: logPath)
        let fm = FileManager.default
        let plistURL = agent.plistURL
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: logPath).deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)

        let domain = "gui/\(getuid())"
        // `bootout` routinely fails — usually there is nothing loaded to remove
        // — so its status is ignored. `bootstrap` is the one that must succeed.
        _ = try? await runLaunchctl(["bootout", "\(domain)/\(label)"], agent: agent)
        do {
            try await runLaunchctl(["bootstrap", domain, plistURL.path], agent: agent)
        } catch {
            try? fm.removeItem(at: plistURL)
            throw error
        }
    }

    /// Turning it off has to actually turn it off. The plist is removed even
    /// when `bootout` fails — leaving it would let the next login reload a job
    /// the user disabled.
    static func uninstall(agent: Agent = .live) async throws {
        _ = try? await runLaunchctl(["bootout", "gui/\(getuid())/\(label)"], agent: agent)
        try? FileManager.default.removeItem(at: agent.plistURL)
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String], agent: Agent) async throws -> Int32 {
        // Async, and via ChildProcess: this used to be two blocking
        // `waitUntilExit()` calls made from a synchronous @MainActor function,
        // i.e. the main thread waiting on a subprocess, with the same
        // read-after-wait pipe shape that deadlocks on a chatty child.
        let output = try await ChildProcess.run(
            executable: agent.launchctl,
            arguments: arguments)
        if !output.isSuccess {
            let text = output.stderrText
            throw ScheduledVerificationError(message: text.isEmpty
                ? "launchctl \(arguments.first ?? "") exited \(output.status)"
                : text)
        }
        return output.status
    }

    /// Exit 1: the library was read and something is wrong with it.
    static let issuesMessage = "Verification found issues — see the PhotoDrop log."
    /// Exit 2: the library could not be checked at all. A different event, and
    /// the reason this isn't one shared message.
    static let cannotVerifyMessage = "Could not verify your library — no manifest found, or it is unreadable."

    private static func appleScript(message: String) -> String {
        // AppleScript string literals escape with a backslash, same as C.
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "display notification \"\(escaped)\" with title \"PhotoDrop\""
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
