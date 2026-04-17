import SwiftUI

struct MainView: View {
    @State private var source: DetectedDrive? = Sample.cards.first
    @State private var primaryDestination: String = "/Users/tim/Photos/RAW"
    @State private var archiveDestination: String = ""
    @State private var descriptionText: String = ""
    @State private var verify: Bool = true
    @State private var ejectWhenDone: Bool = false
    @State private var showInspector: Bool = true

    var body: some View {
        DetailPane(source: source)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    SourcePicker(selection: $source)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        // TODO: refresh detected drives
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh cards")

                    Button {
                        // TODO: eject selected drive
                    } label: {
                        Label("Eject", systemImage: "eject")
                    }
                    .disabled(source == nil)
                    .help("Eject card")
                }
            }
            .inspector(isPresented: $showInspector) {
                InspectorPane(
                    primary: $primaryDestination,
                    archive: $archiveDestination,
                    description: $descriptionText,
                    verify: $verify,
                    ejectWhenDone: $ejectWhenDone,
                    canStart: source != nil
                )
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
            .navigationTitle("")
    }
}

struct SourcePicker: View {
    @Binding var selection: DetectedDrive?

    var body: some View {
        Menu {
            if Sample.cards.isEmpty {
                Text("No cards detected")
            } else {
                ForEach(Sample.cards) { card in
                    Button {
                        selection = card
                    } label: {
                        Label(card.label, systemImage: "sdcard.fill")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection == nil ? "sdcard" : "sdcard.fill")
                    .foregroundStyle(selection == nil ? Color.secondary : Color.accentColor)
                Text(selection?.label ?? "No card")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct DetailPane: View {
    let source: DetectedDrive?

    var body: some View {
        if let source {
            VStack(alignment: .leading, spacing: 0) {
                SourceSummary(source: source)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                Divider()
                PreviewTree(nodes: Sample.previewTree)
            }
        } else {
            ContentUnavailableView(
                "No card inserted",
                systemImage: "sdcard",
                description: Text("Insert a memory card to begin ingest.")
            )
        }
    }
}

struct SourceSummary: View {
    let source: DetectedDrive

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "sdcard.fill")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(source.label)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 10) {
                    Text("\(source.photoCount.formatted()) photos")
                    Text("·").foregroundStyle(.tertiary)
                    Text(source.totalBytes.formatted(.byteCount(style: .file)))
                    Text("·").foregroundStyle(.tertiary)
                    Text(source.mountPoint)
                        .foregroundStyle(.tertiary)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
        }
    }
}
