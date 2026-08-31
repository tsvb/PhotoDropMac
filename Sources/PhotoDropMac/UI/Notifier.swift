import Foundation
import UserNotifications
import AppKit

/// Posts a Notification Center banner when an ingest finishes. Most useful for
/// the menu-bar / backgrounded flow, where the in-app completion sheet isn't
/// visible — so it's skipped while the app is frontmost (the sheet covers that
/// case). Gated by `photodrop.notifyOnCompletion` (default on).
enum Notifier {
    /// "Notify me when an ingest finishes." Governs the *completion* banners
    /// only — see `notifyHookFailure` for why a hook failure is not gated on it.
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "photodrop.notifyOnCompletion") as? Bool ?? true
    }

    /// Key for "the system refused us permission to post banners".
    ///
    /// Authorization was requested lazily inside `post`, with the result
    /// discarded by a `try?`. Two consequences, both silent: the prompt appeared
    /// at the worst possible moment — deliberately while the app is *not*
    /// frontmost, since that is the only time a banner is posted — and if the
    /// user said no, the Settings toggle read checked forever while nothing was
    /// ever delivered.
    static let deniedKey = "photodrop.notify.authorizationDenied"

    static var authorizationDenied: Bool {
        UserDefaults.standard.bool(forKey: deniedKey)
    }

    /// Ask now, in context — called when the user turns the setting on, while
    /// they are looking at Settings and can answer the prompt. Records the
    /// answer so the toggle can stop claiming something that will not happen.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        UserDefaults.standard.set(!granted, forKey: deniedKey)
        return granted
    }

    /// Ask only if the system has no answer on file yet.
    ///
    /// Called at launch (see `AppDelegate`), where the app is frontmost and the
    /// prompt is in context. Once the user has answered — either way — this does
    /// nothing, so it never re-nags and never overwrites a real denial.
    static func requestAuthorizationIfNeverAsked() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = await requestAuthorization()
    }

    @MainActor
    static func notifyCompletion(result: CopyResult) {
        guard enabled, !NSApp.isActive else { return }
        let title = result.filesFailed > 0 ? "Ingest completed with errors" : "Ingest complete"
        var parts = ["\(result.filesCopied) copied"]
        if result.filesSkipped > 0 { parts.append("\(result.filesSkipped) skipped") }
        if result.filesFailed > 0 { parts.append("\(result.filesFailed) failed") }
        var body = parts.joined(separator: ", ") + " · " + result.totalBytes.formatted(.byteCount(style: .file))
        if result.wasEjected { body += " · card ejected" }
        post(title: title, body: body)
    }

    @MainActor
    static func notifyHalt(reason: String) {
        guard enabled, !NSApp.isActive else { return }
        post(title: "Ingest halted", body: "Stopped on \(reason) — see the app for details.")
    }

    /// A configured post-ingest hook failed. Posted regardless of whether the app
    /// is frontmost — unlike the completion banners there's no in-app surface for
    /// it, so the user would otherwise never learn the hook broke.
    @MainActor
    static func notifyHookFailure(message: String) {
        // **Not** gated on `enabled`. That key is "notify me when an ingest
        // finishes", and turning it off silenced the one class of failure with
        // no other surface anywhere in the app — the comment directly above says
        // so, and the guard contradicted it. A user who doesn't want completion
        // banners has not asked to stop being told their hook is broken.
        post(title: "Post-ingest hook failed", body: message)
    }

    private static func post(title: String, body: String) {
        // Fire-and-forget. Build the non-Sendable UNUserNotificationCenter /
        // content objects inside the Task so nothing non-Sendable is captured
        // across an isolation boundary (Swift 6 strict concurrency).
        Task {
            let center = UNUserNotificationCenter.current()

            // **Ask nothing here.** Authorization is requested in Settings, in
            // context, when the user turns notifications on — see
            // `requestAuthorization`. Requesting it from `post` put the system
            // prompt on screen at the worst possible moment by construction:
            // `post` runs only while the app is *not* frontmost, so the prompt
            // interrupted whatever the user was actually doing. It also wrote
            // `deniedKey` from a prompt they may have dismissed rather than
            // denied, leaving Settings claiming a refusal that never happened.
            //
            // Read the existing settings instead, and record a real denial so
            // Settings can stop showing a checked toggle that produces nothing.
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                UserDefaults.standard.set(false, forKey: deniedKey)
            case .denied:
                UserDefaults.standard.set(true, forKey: deniedKey)
                return
            case .notDetermined:
                // Never asked — because the user never turned the setting on in
                // Settings, or turned it on before this code existed. Say nothing
                // and post nothing; the Settings row is where the ask belongs.
                return
            @unknown default:
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // nil trigger → deliver immediately.
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
