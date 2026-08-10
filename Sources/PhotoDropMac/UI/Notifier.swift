import Foundation
import UserNotifications
import AppKit

/// Posts a Notification Center banner when an ingest finishes. Most useful for
/// the menu-bar / backgrounded flow, where the in-app completion sheet isn't
/// visible — so it's skipped while the app is frontmost (the sheet covers that
/// case). Gated by `photodrop.notifyOnCompletion` (default on).
enum Notifier {
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
        guard enabled else { return }
        post(title: "Post-ingest hook failed", body: message)
    }

    private static func post(title: String, body: String) {
        // Fire-and-forget. Build the non-Sendable UNUserNotificationCenter /
        // content objects inside the Task so nothing non-Sendable is captured
        // across an isolation boundary (Swift 6 strict concurrency).
        Task {
            let center = UNUserNotificationCenter.current()
            guard let granted = try? await center.requestAuthorization(options: [.alert, .sound]),
                  granted else {
                // Record the refusal so Settings can say so, rather than leaving
                // a checked toggle that never produces a banner.
                UserDefaults.standard.set(true, forKey: deniedKey)
                return
            }
            UserDefaults.standard.set(false, forKey: deniedKey)
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
