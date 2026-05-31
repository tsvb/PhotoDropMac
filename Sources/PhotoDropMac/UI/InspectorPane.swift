import SwiftUI
import AppKit

struct InspectorPane: View {
    @AppStorage("photodrop.primaryDestination") private var primary: String = ""
    @AppStorage("photodrop.archiveDestination") private var archive: String = ""
    @AppStorage("photodrop.extraArchiveDestinations") private var extraArchives: String = ""
    @AppStorage("photodrop.verifyCopies") private var verify: Bool = true
    @AppStorage("photodrop.ejectAfterIngest") private var ejectWhenDone: Bool = false
    @AppStorage("photodrop.template.folder") private var folderTemplate = NamingTemplate.default.folder
    @AppStorage("photodrop.template.filename") private var fileTemplate = NamingTemplate.default.filename
    @Binding var description: String
    let canStart: Bool
    let onIngest: () -> Void
    let presetStore: PresetStore

    @State private var showingSaveDialog = false
    @State private var newPresetName = ""

    var body: some View {
        Form {
            Section("Presets") {
                Menu {
                    if presetStore.presets.isEmpty {
                        Text("No presets saved")
                    } else {
                        ForEach(presetStore.presets) { preset in
                            Button(preset.name) { preset.apply() }
                        }
                        Divider()
                        Menu("Delete") {
                            ForEach(presetStore.presets) { preset in
                                Button(preset.name, role: .destructive) { presetStore.delete(preset) }
                            }
                        }
                    }
                    Divider()
                    Button("Save Current as Preset…") {
                        newPresetName = ""
                        showingSaveDialog = true
                    }
                } label: {
                    Label("Apply or save a preset", systemImage: "slider.horizontal.3")
                }
            }

            Section {
                LabeledField(label: "Primary") {
                    PathField(path: $primary, prompt: "Choose folder…")
                }
                LabeledField(label: "Archive") {
                    PathField(path: $archive, prompt: "Second copy (optional)")
                }
                ExtraDestinationsEditor(serialized: $extraArchives)
            } header: {
                Text("Destinations")
            } footer: {
                Text(destinationSummary)
            }

            Section("Description") {
                TextField("Description", text: $description, prompt: Text("e.g. Iceland"))
                    .labelsHidden()
            }

            Section("Naming") {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        templateField(label: "Day folder", text: $folderTemplate,
                                      placeholder: NamingTemplate.default.folder)
                        templateField(label: "File name", text: $fileTemplate,
                                      placeholder: NamingTemplate.default.filename)
                        Button("Reset to defaults") {
                            folderTemplate = NamingTemplate.default.folder
                            fileTemplate = NamingTemplate.default.filename
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Folder structure")
                        Text(NamingTemplate.samplePath(folder: folderTemplate, filename: fileTemplate))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }

            Section {
                Toggle("Verify copies with xxHash", isOn: $verify)
                    .toggleStyle(.checkbox)
                Toggle("Eject card when finished", isOn: $ejectWhenDone)
                    .toggleStyle(.checkbox)
            } header: {
                Text("Options")
            } footer: {
                if verify {
                    Text("Every file is hash-checked after copy. Recommended.")
                }
            }

            Section {
                Button {
                    onIngest()
                } label: {
                    Text("Ingest")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canStart || primary.isEmpty)
                .keyboardShortcut(.defaultAction)
            } footer: {
                if primary.isEmpty {
                    Text("Pick a destination to enable Ingest. PhotoDrop will remember it for every card.")
                }
            }
        }
        .formStyle(.grouped)
        .alert("Save Preset", isPresented: $showingSaveDialog) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") {
                let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                presetStore.add(IngestPreset.capture(name: name))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current destinations, naming templates, and verify/eject options.")
        }
    }

    // How many independent verified copies this configuration will write:
    // the primary (if set) plus each distinct archive/mirror location.
    private var destinationSummary: String {
        let mirrors = ArchiveDestinations.list(archive: archive, extra: extraArchives).count
        let total = (primary.isEmpty ? 0 : 1) + mirrors
        switch total {
        case 0:  return "Choose a primary destination to begin."
        case 1:  return "Writes 1 verified copy. Add an archive for redundancy."
        default: return "Writes \(total) independent verified copies — every file lands in all \(total)."
        }
    }

    @ViewBuilder
    private func templateField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text, prompt: Text(placeholder))
                .labelsHidden()
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
        }
    }
}

// Inline editor for the additional mirror destinations (beyond Primary +
// Archive). Backed by the single newline-separated `extraArchiveDestinations`
// default, but presented as stable-identity rows so each path edits cleanly and
// gets its own remove button. Rows own the truth while visible; the serialized
// default is the durable store, re-derived only on a genuine external change.
private struct ExtraDestinationsEditor: View {
    @Binding var serialized: String
    @State private var rows: [Row]
    @State private var syncedFrom: String

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var path: String
    }

    init(serialized: Binding<String>) {
        _serialized = serialized
        let initial = serialized.wrappedValue
        _rows = State(initialValue: Self.parse(initial))
        _syncedFrom = State(initialValue: initial)
    }

    var body: some View {
        ForEach($rows) { $row in
            HStack(spacing: 8) {
                PathField(path: $row.path, prompt: "Additional copy…")
                Button(role: .destructive) {
                    rows.removeAll { $0.id == row.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Remove this copy")
            }
        }
        Button {
            rows.append(Row(path: ""))
        } label: {
            Label("Add a copy", systemImage: "plus.circle")
        }
        .controlSize(.small)
        .onChange(of: rows) { _, _ in
            let joined = serialize()
            syncedFrom = joined
            serialized = joined
        }
        .onChange(of: serialized) { _, new in
            // Re-derive on an external change (e.g. an edit in Settings), but
            // ignore the echo of our own write so an in-progress blank row
            // isn't yanked away.
            guard new != syncedFrom else { return }
            rows = Self.parse(new)
            syncedFrom = new
        }
    }

    private func serialize() -> String {
        rows.map { $0.path.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func parse(_ s: String) -> [Row] {
        s.split(separator: "\n", omittingEmptySubsequences: true)
            .map { Row(path: $0.trimmingCharacters(in: .whitespaces)) }
    }
}

// A stacked caption label above its field — used for the destination paths,
// which are too wide for a leading-label LabeledContent row.
private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct PathField: View {
    @Binding var path: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            TextField("Path", text: $path, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
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

#Preview {
    InspectorPane(description: .constant("Iceland trip"), canStart: true, onIngest: {},
                  presetStore: PresetStore())
        .frame(width: 320, height: 560)
}
