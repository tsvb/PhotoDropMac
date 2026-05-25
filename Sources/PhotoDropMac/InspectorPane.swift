import SwiftUI
import AppKit

struct InspectorPane: View {
    @AppStorage("photodrop.primaryDestination") private var primary: String = ""
    @AppStorage("photodrop.archiveDestination") private var archive: String = ""
    @AppStorage("photodrop.verifyCopies") private var verify: Bool = true
    @AppStorage("photodrop.ejectAfterIngest") private var ejectWhenDone: Bool = false
    @Binding var description: String
    let canStart: Bool
    let onIngest: () -> Void

    var body: some View {
        Form {
            Section("Destinations") {
                LabeledField(label: "Primary") {
                    PathField(path: $primary, prompt: "Choose folder…")
                }
                LabeledField(label: "Archive") {
                    PathField(path: $archive, prompt: "Second copy (optional)")
                }
            }

            Section("Description") {
                TextField("Description", text: $description, prompt: Text("e.g. Iceland"))
                    .labelsHidden()
            }

            Section {
                Toggle("Verify copies with xxHash", isOn: $verify)
                Toggle("Eject card when finished", isOn: $ejectWhenDone)
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
    InspectorPane(description: .constant("Iceland trip"), canStart: true, onIngest: {})
        .frame(width: 320, height: 560)
}
