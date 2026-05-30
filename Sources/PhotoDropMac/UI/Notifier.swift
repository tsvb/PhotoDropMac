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
                  granted else { return }
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
