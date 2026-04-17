import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("General", systemImage: "gearshape") }
            IngestPreferences()
                .tabItem { Label("Ingest", systemImage: "square.and.arrow.down") }
        }
        .frame(width: 520, height: 340)
    }
}

struct GeneralPreferences: View {
    @AppStorage("defaultPrimaryDestination") private var defaultPrimary: String = ""
    @AppStorage("defaultArchiveDestination") private var defaultArchive: String = ""

    var body: some View {
        Form {
            Section("Defaults") {
                TextField("Primary destination", text: $defaultPrimary)
                TextField("Archive destination", text: $defaultArchive)
            }
        }
        .formStyle(.grouped)
    }
}

struct IngestPreferences: View {
    @AppStorage("verifyByDefault") private var verifyByDefault: Bool = true
    @AppStorage("ejectAfterIngest") private var ejectAfterIngest: Bool = false
    @AppStorage("showCompletionDialog") private var showCompletionDialog: Bool = true

    var body: some View {
        Form {
            Section("Defaults") {
                Toggle("Verify copies with xxHash", isOn: $verifyByDefault)
                Toggle("Eject card when finished", isOn: $ejectAfterIngest)
                Toggle("Show completion summary", isOn: $showCompletionDialog)
            }
        }
        .formStyle(.grouped)
    }
}
