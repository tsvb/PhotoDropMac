import SwiftUI
import AppKit

@main
struct PhotoDropMacApp: App {
    @State private var watcher = DriveWatcher()

    var body: some Scene {
        Window("PhotoDrop", id: "main") {
            MainView()
                .environment(watcher)
        }
        .defaultSize(width: 1020, height: 700)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarMenu()
                .environment(watcher)
        } label: {
            Image(systemName: watcher.drives.isEmpty ? "sdcard" : "sdcard.fill")
        }

        Settings {
            SettingsView()
        }
    }
}

struct MenuBarMenu: View {
    @Environment(DriveWatcher.self) private var watcher
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let first = watcher.drives.first {
            Button("Ingest from \(first.label)…") {
                openWindow(id: "main")
                NSApp.activate()
            }
            .keyboardShortcut("i")

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
