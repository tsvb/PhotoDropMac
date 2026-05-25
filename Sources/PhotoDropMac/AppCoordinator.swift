import Foundation
import Observation

// App-scoped glue shared by the window and the menu bar. It lets the menu bar
// request a one-click ingest that the window's MainView fulfils with its
// existing scan → plan → copy path — so there is still a single Copier and a
// single progress UI, and the menu-bar path adds no parallel engine.
@MainActor
@Observable
final class AppCoordinator {
    // Set by the menu bar's one-click action; consumed (and cleared) by MainView.
    var pendingOneClickCardID: DetectedDrive.ID?
}

// How the MenuBarExtra is shown. Persisted via @AppStorage as its rawValue.
enum MenuBarVisibility: String, CaseIterable, Identifiable {
    case always, withCard, hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always:   return "Always"
        case .withCard: return "With card"
        case .hidden:   return "Hidden"
        }
    }
}
