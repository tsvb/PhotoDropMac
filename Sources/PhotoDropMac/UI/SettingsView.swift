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
            NamingPreferences()
                .tabItem { Label("Naming", systemImage: "textformat.abc") }
            MenuBarPreferences()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            MaintenancePreferences()
                .tabItem { Label("Maintenance", systemImage: "checkmark.shield") }
        }
        .frame(width: 540, height: 430)
        .tint(theme.accent)
    }
}

struct MaintenancePreferences: View {
    @AppStorage("photodrop.primaryDestination") private var primary: String = ""
    @AppStorage("photodrop.scheduledVerify.enabled") private var enabled: Bool = false
    @AppStorage("photodrop.scheduledVerify.schedule") private var scheduleRaw: String = VerifySchedule.weekly.rawValue
    @AppStorage("photodrop.scheduledVerify.binaryPath") private var binaryPath: String = ""
    @AppStorage("photodrop.scheduledVerify.library") private var libraryOverride: String = ""
    @State private var errorMessage: String?

    private var schedule: VerifySchedule { VerifySchedule(rawValue: scheduleRaw) ?? .weekly }
    private var libraryPath: String { libraryOverride.isEmpty ? primary : libraryOverride }

    // A typed path wins; otherwise fall back to the photodrop bundled inside the
    // app (Contents/MacOS/photodrop). So a distributed build schedules without
    // the user locating or building the CLI.
    private var effectiveBinaryPath: String {
        binaryPath.isEmpty ? (EmbeddedCLI.path ?? "") : binaryPath
    }

    var body: some View {
        Form {
            Section {
                Toggle("Verify the library on a schedule", isOn: $enabled)
                    .disabled(effectiveBinaryPath.isEmpty || libraryPath.isEmpty)
                Picker("How often", selection: $scheduleRaw) {
                    ForEach(VerifySchedule.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .disabled(!enabled)
            } header: {
                Text("Scheduled verification")
            } footer: {
                Text("Runs `photodrop verify` in the background (03:00) via a launchd agent and notifies you if it finds bit-rot or missing files. Report-only — it never changes your library.")
            }

            Section {
                TextField("photodrop CLI", text: $binaryPath,
                          prompt: Text(EmbeddedCLI.path == nil
                                       ? "Path to the photodrop binary"
                                       : "Bundled photodrop — type a path to override"))
                    .lineLimit(1).truncationMode(.middle)
                TextField("Library to verify", text: $libraryOverride,
                          prompt: Text(primary.isEmpty ? "Library folder" : "Defaults to the primary destination"))
                    .lineLimit(1).truncationMode(.middle)
            } footer: {
                if binaryPath.isEmpty {
                    if EmbeddedCLI.path != nil {
                        Text("Using the photodrop tool bundled inside the app. Type a path above to override.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Build the photodrop tool (scheme `photodrop`) and point here to enable scheduling.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { _, _ in apply() }
        .onChange(of: scheduleRaw) { _, _ in if enabled { apply() } }
        .alert("Scheduling failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func apply() {
        do {
            if enabled {
                guard !effectiveBinaryPath.isEmpty, !libraryPath.isEmpty else { enabled = false; return }
                try ScheduledVerification.install(photodropPath: effectiveBinaryPath, libraryPath: libraryPath, schedule: schedule)
            } else {
                try ScheduledVerification.uninstall()
            }
        } catch {
            errorMessage = error.localizedDescription
            if enabled { enabled = false }   // revert on failure
        }
    }
}

struct GeneralPreferences: View {
    @AppStorage("photodrop.primaryDestination") private var primary: String = ""
    @AppStorage("photodrop.archiveDestination") private var archive: String = ""
    @AppStorage("photodrop.extraArchiveDestinations") private var extraArchives: String = ""
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
                TextEditor(text: $extraArchives)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 56)
            } header: {
                Text("Additional archive locations")
            } footer: {
                Text("Optional — one folder path per line. Each gets its own verified copy (e.g. a NAS and an offsite drive for 3-2-1 backups). The Primary and Archive above are always included.")
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
    @AppStorage("photodrop.postIngestScript") private var postIngestScript: String = ""

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

            Section {
                HStack(spacing: 8) {
                    TextField("Run after ingest", text: $postIngestScript,
                              prompt: Text("Path to an executable script (optional)"))
                        .labelsHidden()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        chooseHookScript()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help("Choose script…")
                    if !postIngestScript.isEmpty {
                        Button("Clear") { postIngestScript = "" }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Post-ingest hook")
            } footer: {
                Text("Runs an executable script after each completed ingest (argv[1] is the destination; job details are in PHOTODROP_* environment variables). Best-effort — a failing hook never affects the copy.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseHookScript() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose an executable script to run after each ingest."
        if panel.runModal() == .OK, let url = panel.url {
            postIngestScript = url.path(percentEncoded: false)
        }
    }
}

struct NamingPreferences: View {
    @AppStorage("photodrop.template.folder") private var folder = NamingTemplate.default.folder
    @AppStorage("photodrop.template.filename") private var filename = NamingTemplate.default.filename

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Day folder").font(.caption).foregroundStyle(.secondary)
                    TextField("Day folder", text: $folder, prompt: Text(NamingTemplate.default.folder))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("File name").font(.caption).foregroundStyle(.secondary)
                    TextField("File name", text: $filename, prompt: Text(NamingTemplate.default.filename))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                Button("Reset to defaults") {
                    folder = NamingTemplate.default.folder
                    filename = NamingTemplate.default.filename
                }
                .controlSize(.small)
            } header: {
                Text("Templates")
            } footer: {
                Text("The year is always the top folder. The original file extension is kept automatically.")
            }

            Section("Preview") {
                Text(previewPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                DisclosureGroup("Token reference") {
                    ForEach(NamingTemplate.legend) { item in
                        LabeledContent {
                            Text(item.meaning).font(.caption).foregroundStyle(.secondary)
                        } label: {
                            Text(item.token).font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // Renders the current templates against a fixed sample, exactly as the copy
    // engine would. Shared with the inspector's naming preview.
    private var previewPath: String {
        NamingTemplate.samplePath(folder: folder, filename: filename)
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
