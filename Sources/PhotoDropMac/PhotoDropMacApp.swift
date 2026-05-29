import SwiftUI
import AppKit

@main
struct PhotoDropMacApp: App {
    @State private var watcher = DriveWatcher()
    @State private var coordinator = AppCoordinator()
    @AppStorage("photodrop.menuBar.visibility") private var menuBarVisibility = MenuBarVisibility.always
    @AppStorage("photodrop.verificationStyle") private var theme = VerificationStyle.steady

    var body: some Scene {
        Window("PhotoDrop", id: "main") {
            MainView()
                .environment(watcher)
                .environment(coordinator)
                .tint(theme.accent)
        }
        .defaultSize(width: 1020, height: 700)
        .windowToolbarStyle(.unified)

        // Default (.always) keeps the menu bar — and its card-arrival auto-open —
        // alive exactly as before. .withCard shows it only while a card is
        // mounted; .hidden removes it (which also disables menu-bar auto-open,
        // since the icon is the host that detects arrivals).
        MenuBarExtra(isInserted: .constant(menuBarVisible)) {
            MenuBarMenu()
                .environment(watcher)
                .environment(coordinator)
        } label: {
            MenuBarIcon(watcher: watcher)
        }

        Settings {
            SettingsView()
                .tint(theme.accent)
        }
    }

    private var menuBarVisible: Bool {
        switch menuBarVisibility {
        case .always:   return true
        case .withCard: return !watcher.drives.isEmpty
        case .hidden:   return false
        }
    }
}

// Hosted by MenuBarExtra's label — alive in the scene hierarchy (whenever the
// menu bar is shown) regardless of window visibility. That's what lets us react
// to a drive arriving while the main window is closed.
struct MenuBarIcon: View {
    let watcher: DriveWatcher
    @Environment(\.openWindow) private var openWindow
    @AppStorage("photodrop.menuBar.autoOpenWindow") private var autoOpenWindow: Bool = true

    var body: some View {
        Image(systemName: watcher.drives.isEmpty ? "sdcard" : "sdcard.fill")
            .onChange(of: watcher.drives) { oldValue, newValue in
                guard autoOpenWindow else { return }
                let added = Set(newValue.map(\.id))
                    .subtracting(Set(oldValue.map(\.id)))
                guard !added.isEmpty else { return }
                openWindow(id: "main")
                NSApp.activate()
            }
    }
}

struct MenuBarMenu: View {
    @Environment(DriveWatcher.self) private var watcher
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    @AppStorage("photodrop.primaryDestination") private var primaryDestination: String = ""
    @AppStorage("photodrop.menuBar.oneClickIngest") private var oneClickIngest: Bool = false

    var body: some View {
        if let first = watcher.drives.first {
            Button("Ingest from \(first.label)…") {
                openWindow(id: "main")
                NSApp.activate()
                if oneClickIngest {
                    // The window's MainView watches this and starts the ingest
                    // once the card is scanned and a destination is set.
                    coordinator.pendingOneClickCardID = first.id
                }
            }
            .keyboardShortcut("i")
            .disabled(oneClickIngest && primaryDestination.isEmpty)

            if watcher.drives.count > 1 {
                Text("\(watcher.drives.count) cards available")
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("Open PhotoDrop") {
                openWindow(id: "main")
                NSApp.activate()
            }
            Text("No card inserted")
                .foregroundStyle(.secondary)
        }

        Divider()

        SettingsLink {
            Text("Preferences…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("About PhotoDrop") {
            NSApp.sendAction(#selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: nil, from: nil)
            NSApp.activate()
        }

        Button("Quit PhotoDrop") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
