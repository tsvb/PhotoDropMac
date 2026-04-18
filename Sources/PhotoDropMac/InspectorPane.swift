import SwiftUI
import AppKit

struct InspectorPane: View {
    @AppStorage("photodrop.primaryDestination") private var primary: String = ""
    @AppStorage("photodrop.archiveDestination") private var archive: String = ""
    @AppStorage("photodrop.verifyCopies") private var verify: Bool = true
    @AppStorage("photodrop.ejectAfterIngest") private var ejectWhenDone: Bool = false
    @Binding var description: String
    let canStart: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                destinationSection
                Divider()
                descriptionSection
                Divider()
                optionsSection
                Spacer(minLength: 12)
                startButton
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorLabel("Destination")
            PathField(path: $primary, prompt: "Choose folder...")

            InspectorLabel("Archive", trailing: "optional")
                .padding(.top, 2)
            PathField(path: $archive, prompt: "Second copy location")
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorLabel("Description")
            TextField("e.g. Wedding, Iceland trip", text: $description)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Verify copies with xxHash", isOn: $verify)
            Toggle("Eject card when finished", isOn: $ejectWhenDone)
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private var startButton: some View {
        Button {
            // TODO: start ingest
        } label: {
            Text("Ingest")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canStart || primary.isEmpty)
        .keyboardShortcut(.defaultAction)
    }
}

struct InspectorLabel: View {
    let title: String
    let trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}

struct PathField: View {
    @Binding var path: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            TextField(prompt, text: $path)
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
