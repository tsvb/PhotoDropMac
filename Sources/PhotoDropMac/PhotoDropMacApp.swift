import SwiftUI
import AppKit

@main
struct PhotoDropMacApp: App {
    var body: some Scene {
        Window("PhotoDrop", id: "main") {
            MainView()
        }
        .defaultSize(width: 1020, height: 700)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarMenu()
        } label: {
            Image(systemName: Sample.cards.isEmpty ? "sdcard" : "sdcard.fill")
        }

        Settings {
            SettingsView()
        }
    }
}

struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let firstCardLabel = Sample.cards.first?.label

        Button(firstCardLabel.map { "Ingest from \($0)…" } ?? "Open PhotoDrop") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("i")

        if firstCardLabel == nil {
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
