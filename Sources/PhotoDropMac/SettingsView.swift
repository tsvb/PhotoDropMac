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
        }
        .frame(width: 540, height: 430)
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
    // engine would (sanitize the rendered output into path components).
    private var previewPath: String {
        let context = TemplateContext(
            date: sampleDate,
            description: PathPlanner.sanitize("Iceland"),
            originalName: "L1031253.DNG",
            originalStem: "L1031253",
            cardLabel: PathPlanner.sanitize("LEICA DLUX8")
        )
        let leaf = PathPlanner.sanitize(TemplateRenderer.render(folder, context))
        let stem = PathPlanner.sanitize(TemplateRenderer.render(filename, context))
        let year = Calendar.current.component(.year, from: sampleDate)
        let safeLeaf = leaf.isEmpty ? "2026-05-28" : leaf
        let safeStem = stem.isEmpty ? "20260528_195510_L1031253" : stem
        return "…/\(year)/\(safeLeaf)/\(safeStem).DNG"
    }

    private var sampleDate: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 28
        c.hour = 19; c.minute = 55; c.second = 10
        return Calendar.current.date(from: c) ?? .now
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
