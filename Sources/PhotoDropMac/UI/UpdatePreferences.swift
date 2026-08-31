import SwiftUI

/// Settings → Updates.
///
/// Its own file rather than another view inside `SettingsView.swift`, which is
/// already long enough that the type checker's cost on it has been measured and
/// commented on twice.
///
/// The pane states the two things a user of a photo-ingest tool is entitled to
/// know before letting it update itself: **where** the feed lives, and that
/// every update is checked against a signing key baked into the copy they are
/// already running. When the build cannot update, it says so plainly instead of
/// showing controls that do nothing.
struct UpdatePreferences: View {
    @Environment(SoftwareUpdater.self) private var updater

    var body: some View {
        @Bindable var updater = updater

        Form {
            if let explanation = updater.configuration.explanation {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Open the Releases Page") { AppLinks.open(.releases) }
                } header: {
                    Text("Updates are unavailable in this build")
                }
            } else {
                Section {
                    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                    Picker("How often", selection: $updater.cadence) {
                        ForEach(UpdateCadence.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!updater.automaticallyChecksForUpdates)
                    Toggle("Download and install updates automatically",
                           isOn: $updater.automaticallyDownloadsUpdates)
                        // Sparkle refuses in-place installation when the app
                        // cannot be replaced where it is — running from the DMG
                        // is the common case. Showing the toggle live there
                        // would promise something that silently never happens.
                        .disabled(!updater.automaticallyChecksForUpdates || !updater.allowsAutomaticUpdates)
                } header: {
                    Text("Automatic updates")
                } footer: {
                    Text("An update is never installed while an ingest is running — PhotoDrop waits for the copy to finish and its manifest to be written first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PhotoDrop \(Self.currentVersion)")
                            Text(lastCheckedText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                    if updater.gate == .holdUntilTheJobFinishes {
                        Text("An ingest is running. PhotoDrop will check for updates once it has finished.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if let feed = updater.configuration.feed {
                        Text("Updates come from \(feed.absoluteString) and are only installed if they are signed with the key built into this copy of PhotoDrop. This is the only network connection PhotoDrop makes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var lastCheckedText: String {
        guard let date = updater.lastCheckDate else { return "Never checked for updates" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Read from the bundle rather than a literal, for the reason the CLI's
    /// `--version` is: a literal drifted two releases behind `MARKETING_VERSION`
    /// and a build that misreports itself makes a support conversation
    /// impossible.
    static var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
