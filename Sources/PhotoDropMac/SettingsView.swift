import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("photodrop.verificationStyle") private var theme = VerificationStyle.steady

    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("General", systemImage: "gearshape") }
            IngestPreferences()
                .tabItem { Label("Ingest", systemImage: "square.and.arrow.down") }
            MenuBarPreferences()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
        }
        .frame(width: 520, height: 360)
        .tint(theme.accent)
    }
}

struct GeneralPreferences: View {
    @AppStorage("photodrop.primaryDestination") private var primary: String = ""
    @AppStorage("photodrop.archiveDestination") private var archive: String = ""
    @AppStorage("photodrop.verificationStyle") private var verificationStyle = VerificationStyle.steady

    var body: some View {
        Form {
            Section("Destinations") {
                SettingsPathRow(
                    label: "Primary",
                    path: $primary,
                    prompt: "Choose folder..."
                )
                SettingsPathRow(
                    label: "Archive",
                    path: $archive,
                    prompt: "Second copy location"
                )
            }

            Section {
                Picker("Theme", selection: $verificationStyle) {
                    ForEach(VerificationStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text(verificationStyle.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct IngestPreferences: View {
    @AppStorage("photodrop.verifyCopies") private var verify: Bool = true
    @AppStorage("photodrop.ejectAfterIngest") private var ejectAfterIngest: Bool = false
    @AppStorage("photodrop.showCompletionSheet") private var showCompletionSheet: Bool = true
    @AppStorage("photodrop.notifyOnCompletion") private var notifyOnCompletion: Bool = true

    var body: some View {
        Form {
            Section("Defaults") {
                Toggle("Verify copies with xxHash", isOn: $verify)
                Toggle("Eject card when finished", isOn: $ejectAfterIngest)
                Toggle("Show completion summary", isOn: $showCompletionSheet)
            }

            Section {
                Toggle("Notify when finished", isOn: $notifyOnCompletion)
            } footer: {
                Text("Posts a notification when an ingest completes while PhotoDrop is in the background.")
            }
        }
        .formStyle(.grouped)
    }
}

struct MenuBarPreferences: View {
    @AppStorage("photodrop.menuBar.visibility") private var visibility = MenuBarVisibility.always
    @AppStorage("photodrop.menuBar.autoOpenWindow") private var autoOpenWindow: Bool = true
    @AppStorage("photodrop.menuBar.oneClickIngest") private var oneClickIngest: Bool = false
    @AppStorage("photodrop.primaryDestination") private var primaryDestination: String = ""

    var body: some View {
        Form {
            Section("Menu bar status") {
                Picker("Show in menu bar", selection: $visibility) {
                    ForEach(MenuBarVisibility.allCases) { v in
                        Text(v.label).tag(v)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Auto-open window when a card arrives", isOn: $autoOpenWindow)
            }

            Section {
                Toggle("One-click ingest from menu bar", isOn: $oneClickIngest)
            } footer: {
                if oneClickIngest && primaryDestination.isEmpty {
                    Text("Set a primary destination in General to enable one-click ingest.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Uses your default destination and verify settings. Still hash-checks every file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsPathRow: View {
    let label: String
    @Binding var path: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            TextField(label, text: $path, prompt: Text(prompt))
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                chooseFolder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
            .help("Choose folder…")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path(percentEncoded: false)
        }
    }
}
