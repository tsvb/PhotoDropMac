import SwiftUI
import AppKit

@main
struct PhotoDropMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var watcher = DriveWatcher()
    @State private var coordinator = AppCoordinator()
    /// Owned by the *app*, not the window.
    ///
    /// As `MainView` state it died with the window: closing the window during a
    /// copy left the detached engine running with a nil `[weak self]` (so the
    /// completion notification and the post-ingest hook were skipped), and
    /// reopening minted a fresh `Copier` sitting at `.idle` — an app reporting
    /// no ingest while one was in progress.
    @State private var copier = Copier()
    @State private var jobRegistry = JobRegistry()
    @AppStorage("photodrop.menuBar.visibility") private var menuBarVisibility = MenuBarVisibility.always
    @AppStorage("photodrop.verificationStyle") private var theme = VerificationStyle.steady

    var body: some Scene {
        Window("PhotoDrop", id: "main") {
            MainView()
                .environment(watcher)
                .environment(coordinator)
                .environment(copier)
                .task { wireJobRegistry() }
                .tint(theme.accent)
                .fontDesign(theme.fontDesign)
                .preferredColorScheme(theme.colorScheme)
        }
        .defaultSize(width: 1020, height: 700)
        .windowToolbarStyle(.unified)
        .commands { PhotoDropCommands(coordinator: coordinator) }

        // Default (.always) keeps the menu bar — and its card-arrival auto-open —
        // alive exactly as before. .withCard shows it only while a card is
        // mounted; .hidden removes it (which also disables menu-bar auto-open,
        // since the icon is the host that detects arrivals).
        MenuBarExtra(isInserted: .constant(menuBarVisible)) {
            MenuBarMenu()
                .environment(watcher)
                .environment(coordinator)
        } label: {
            MenuBarIcon(watcher: watcher)
        }

        Settings {
            SettingsView()
                .tint(theme.accent)
                .fontDesign(theme.fontDesign)
                .preferredColorScheme(theme.colorScheme)
        }
        .windowResizability(.contentSize)
    }

    /// The delegate is constructed by AppKit and has no access to scene state,
    /// so the connection is made from here, once.
    @MainActor
    private func wireJobRegistry() {
        copier.registry = jobRegistry
        appDelegate.registry = jobRegistry
    }

    private var menuBarVisible: Bool {
        switch menuBarVisibility {
        case .always:   return true
        case .withCard: return !watcher.drives.isEmpty
        case .hidden:   return false
        }
    }
}

/// Menu items for the actions that previously lived only in the toolbar.
///
/// Without these, Refresh / Verify Library / Toggle Inspector / Cancel were
/// unreachable from the menu bar — and therefore from Help-menu search and from
/// anyone driving the app by keyboard. The commands go through `AppCoordinator`
/// because a `Commands` builder is scene-scoped and cannot see window state.
struct PhotoDropCommands: Commands {
    let coordinator: AppCoordinator

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Refresh") { coordinator.requestRefresh() }
                .keyboardShortcut("r")
            Button("Toggle Inspector") { coordinator.requestToggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Ingest") {
            Button("Verify Library…") { coordinator.requestVerifyLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Cancel Ingest") { coordinator.requestCancel() }
                .keyboardShortcut(".", modifiers: .command)
        }

        // macOS renders a Help menu whether or not anything is behind it, and
        // ours opened nothing. There was also no way, anywhere in the shipped
        // app, to reach the project, report a problem, or discover that a
        // command-line tool ships inside the bundle.
        CommandGroup(replacing: .help) {
            Button("PhotoDrop Help") { AppLinks.open(.readme) }
            Divider()
            Button("Report an Issue…") { AppLinks.open(.issues) }
            Button("Check for Updates…") { AppLinks.open(.releases) }
            Divider()
            Button("Install Command Line Tool…") { AppLinks.revealCommandLineTool() }
                .disabled(EmbeddedCLI.path == nil)
        }
    }
}

/// The handful of outward links the app offers, in one place.
///
/// Deliberately links rather than in-app network calls: the app makes no network
/// connections of its own, which is a property worth keeping for a tool that
/// reads people's photo libraries and filesystem paths. "Check for Updates"
/// opens the releases page in the user's browser rather than phoning home.
enum AppLinks {
    enum Destination {
        case readme, issues, releases

        var url: URL {
            switch self {
            case .readme:   URL(string: "https://github.com/tsvb/PhotoDropMac#readme")!
            case .issues:   URL(string: "https://github.com/tsvb/PhotoDropMac/issues/new")!
            case .releases: URL(string: "https://github.com/tsvb/PhotoDropMac/releases")!
            }
        }
    }

    static func open(_ destination: Destination) {
        NSWorkspace.shared.open(destination.url)
    }

    /// Reveal the embedded `photodrop` binary in Finder.
    ///
    /// The tool is signed and notarized inside the app — an elegant zero-install
    /// distribution — and completely undiscoverable: not on `PATH`, mentioned
    /// only around line 200 of the README, and never named anywhere in the UI
    /// despite Settings → Maintenance using it internally. Revealing it, rather
    /// than symlinking it into `/usr/local/bin` on the user's behalf, keeps the
    /// app out of directories it has no business writing to unasked.
    static func revealCommandLineTool() {
        guard let path = EmbeddedCLI.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Turns a quit request into the graceful-cancel path.
///
/// Quit was wired straight to `NSApp.terminate(nil)`. `FileCopier`'s partial
/// cleanup is a Swift `catch`, which process death skips — and the half-written
/// file that leaves is invisible afterwards to everything this app can do: not
/// in the manifest (written after the loop), never xattr-stamped, and on a
/// re-ingest its size differs so dedup misses it and `CopyPlan` pushes the real
/// file to `…_1`. Cancelling instead stops at a file boundary, rolls back the
/// bundle in flight, and still writes the manifest and log — exactly what the
/// CLI does for SIGTERM.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var registry: JobRegistry?

    /// Ask for notification permission at launch, while the app is frontmost.
    ///
    /// `Notifier.post` deliberately no longer asks: it runs only when the app is
    /// *not* frontmost, so asking there put the system prompt on screen over
    /// whatever the user was actually doing, and recorded a dismissal as a
    /// denial. But the completion-banner setting defaults to **on**, so a user
    /// who never visits Settings had never been asked at all — and would have
    /// silently got nothing. Launch is the one moment that is both in-context and
    /// certain to happen. `Notifier.requestAuthorization` is a no-op once the
    /// system has an answer on file, so this prompts exactly once.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard UserDefaults.standard.object(forKey: "photodrop.notifyOnCompletion") as? Bool ?? true
        else { return }
        Task { await Notifier.requestAuthorizationIfNeverAsked() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let copier = registry?.runningCopier,
              TerminationPolicy.decide(hasRunningJob: copier.isRunning) == .waitForTheJobToStop
        else { return .terminateNow }

        Task { @MainActor in
            await copier.stopForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// Hosted by MenuBarExtra's label — alive in the scene hierarchy (whenever the
// menu bar is shown) regardless of window visibility. That's what lets us react
// to a drive arriving while the main window is closed.
struct MenuBarIcon: View {
    let watcher: DriveWatcher
    @Environment(\.openWindow) private var openWindow
    @AppStorage("photodrop.menuBar.autoOpenWindow") private var autoOpenWindow: Bool = true

    var body: some View {
        Image(systemName: watcher.drives.isEmpty ? "sdcard" : "sdcard.fill")
            .accessibilityLabel(watcher.drives.isEmpty ? "PhotoDrop, no card inserted" : "PhotoDrop, card inserted")
            // `initial: true` is load-bearing. In `.withCard` mode this label is
            // *created by* the arrival it needs to observe, so without an initial
            // delivery the first card of a session never opened the window — see
            // `MenuBarAutoOpen`.
            .onChange(of: watcher.drives, initial: true) { oldValue, newValue in
                guard autoOpenWindow else { return }
                guard MenuBarAutoOpen.shouldOpen(previous: oldValue.map(\.id),
                                                 current: newValue.map(\.id),
                                                 isInitial: oldValue.map(\.id) == newValue.map(\.id))
                else { return }
                openWindow(id: "main")
                NSApp.activate()
            }
    }
}

struct MenuBarMenu: View {
    @Environment(DriveWatcher.self) private var watcher
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    @AppStorage("photodrop.primaryDestination") private var primaryDestination: String = ""
    @AppStorage("photodrop.menuBar.oneClickIngest") private var oneClickIngest: Bool = false

    var body: some View {
        if let first = watcher.drives.first {
            Button("Ingest from \(first.label)…") {
                openWindow(id: "main")
                NSApp.activate()
                if oneClickIngest {
                    // The window's MainView watches this and starts the ingest
                    // once the card is scanned and a destination is set.
                    coordinator.pendingOneClickCardID = first.id
                }
            }
            .keyboardShortcut("i")
            .disabled(oneClickIngest && primaryDestination.isEmpty)

            if watcher.drives.count > 1 {
                Text("\(watcher.drives.count) cards available")
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("Open PhotoDrop") {
                openWindow(id: "main")
                NSApp.activate()
            }
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
