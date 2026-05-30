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

    private static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // nil trigger → deliver immediately.
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
