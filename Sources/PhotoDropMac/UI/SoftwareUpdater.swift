import Foundation
import Observation
import Sparkle

/// The app's one point of contact with Sparkle.
///
/// **This is the only outbound network connection PhotoDrop makes**, which is
/// why it is concentrated here rather than sprinkled across views, and why the
/// rules around it are written down:
///
/// - **An unconfigured build never starts Sparkle at all.** If the Info.plist
///   has no https feed or no Ed25519 public key, `configuration` is not `.ready`
///   and no `SPUUpdaterController` is created — so a build from source is
///   exactly as silent as the app was before updates existed, instead of
///   quietly failing checks against a feed it cannot verify.
/// - **The user is asked before the first check.** No `SUEnableAutomaticChecks`
///   key is set, so Sparkle's own permission prompt runs before any network
///   activity. Nothing leaves the machine on a fresh install until someone says
///   yes. (See PRIVACY.md, which states this as a promise.)
/// - **An ingest outranks an update** — `UpdateGate`. Sparkle's terminal act is
///   to replace and relaunch the application, and this app's job is a copy whose
///   only safe stopping point is a file boundary.
///
/// Sparkle owns the stored settings (`SUEnableAutomaticChecks`,
/// `SUScheduledCheckInterval`, `SUAutomaticallyUpdate` in the app's own defaults
/// domain). This class mirrors them into observable properties for SwiftUI to
/// render, and writes through on every change; it deliberately does **not** keep
/// a second `@AppStorage` copy, which would be free to disagree with the value
/// Sparkle actually acts on.
@MainActor
@Observable
final class SoftwareUpdater {
    /// What the built Info.plist says. Computed once — the plist cannot change
    /// under a running app — and cheap, so `init` still does no I/O worth the
    /// name (see `HashCache`, where an init that read a file cost a main-thread
    /// stall at every window open).
    let configuration: UpdateConfiguration

    /// Set by the app once the scene exists, before Sparkle is started, so the
    /// "is a job running?" gate is live before any check can fire.
    @ObservationIgnored var registry: JobRegistry?

    private(set) var canCheckForUpdates = false
    private(set) var lastCheckDate: Date?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var delegate: UpdaterDelegate?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    // Mirrors of Sparkle's own settings. Private storage + a computed accessor
    // so SwiftUI observes the change and Sparkle remains the source of truth.
    private var storedAutomaticChecks = false
    private var storedAutomaticDownloads = false
    private var storedInterval: TimeInterval = UpdateCadence.weekly.seconds

    init(bundle: Bundle = .main) {
        configuration = UpdateConfiguration.read(
            feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    }

    // MARK: - Lifecycle

    /// Starts Sparkle, if this build can update. Idempotent.
    func start() {
        guard controller == nil, configuration.isReady else { return }

        let delegate = UpdaterDelegate(owner: self)
        self.delegate = delegate
        // `startingUpdater: false` then an explicit start, so the delegate — and
        // through it the running-job gate — is unambiguously in place first.
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: delegate,
                                                      userDriverDelegate: nil)
        self.controller = controller
        controller.startUpdater()

        // KVO rather than a poll: `canCheckForUpdates` goes false for the
        // duration of a check, and a menu item that stays enabled through it
        // invites a second check that Sparkle will refuse.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            // Sparkle posts this on the main thread; it is `NS_SWIFT_UI_ACTOR`
            // throughout.
            MainActor.assumeIsolated { self?.syncFromSparkle() }
        }
        syncFromSparkle()
    }

    // MARK: - Settings, mirrored from Sparkle

    var automaticallyChecksForUpdates: Bool {
        get { storedAutomaticChecks }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            syncFromSparkle()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { storedAutomaticDownloads }
        set {
            controller?.updater.automaticallyDownloadsUpdates = newValue
            syncFromSparkle()
        }
    }

    var cadence: UpdateCadence {
        get { UpdateCadence.closest(to: storedInterval) }
        set {
            controller?.updater.updateCheckInterval = newValue.seconds
            syncFromSparkle()
        }
    }

    /// Sparkle only allows automatic *installation* when the app can be updated
    /// in place (it is not, say, running from a read-only disk image).
    var allowsAutomaticUpdates: Bool { controller?.updater.allowsAutomaticUpdates ?? false }

    private func syncFromSparkle() {
        guard let updater = controller?.updater else { return }
        storedAutomaticChecks = updater.automaticallyChecksForUpdates
        storedAutomaticDownloads = updater.automaticallyDownloadsUpdates
        storedInterval = updater.updateCheckInterval
        lastCheckDate = updater.lastUpdateCheckDate
        canCheckForUpdates = updater.canCheckForUpdates && gate == .allow
    }

    // MARK: - Checking

    var gate: UpdateGate { UpdateGate.decide(hasRunningJob: registry?.runningCopier?.isRunning ?? false) }

    /// A user-initiated check. No-op when the build cannot update — the callers
    /// disable their controls, and `MainMenu`'s Help item falls back to opening
    /// the Releases page.
    func checkForUpdates() {
        guard let controller, gate == .allow else { return }
        controller.updater.checkForUpdates()
    }

    /// Called by the delegate when an update cycle ends, so "Last checked" is
    /// the truth rather than the last time the view happened to be built.
    fileprivate func updateCycleFinished() { syncFromSparkle() }

    /// Called by the delegate when a job is in flight and Sparkle wants to
    /// relaunch. Waits for the copy to reach a file boundary and write its
    /// manifest, then lets the install proceed.
    fileprivate func installWhenTheJobFinishes(_ install: @escaping () -> Void) {
        guard let copier = registry?.runningCopier else { install(); return }
        Task { @MainActor in
            await copier.waitForCompletion()
            install()
        }
    }
}

// MARK: - Delegate

/// Separate from `SoftwareUpdater` because `SPUUpdaterDelegate` inherits
/// `NSObject`, and mixing the `@Observable` macro into an `NSObject` subclass
/// that is also a KVO *observer* is more entanglement than this needs.
///
/// **Every method carries its Objective-C selector explicitly.** These are
/// optional protocol methods: a Swift signature that does not match is not a
/// compile error, it is a method that is simply never called — and the two below
/// are the ones standing between a running ingest and a relaunch.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private weak var owner: SoftwareUpdater?

    init(owner: SoftwareUpdater) {
        self.owner = owner
        super.init()
    }

    @objc(updater:mayPerformUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let gate = owner?.gate ?? .allow
        guard let reason = gate.refusalReason else { return }
        throw NSError(domain: "com.tsvb.PhotoDropMac.updates", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: reason])
    }

    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(_ updater: SPUUpdater,
                 shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Belt and braces with `mayPerformUpdateCheck`: a download can have been
        // approved while the app was idle and reach installation after an ingest
        // has started (Sparkle installs on quit, and `AppDelegate` defers quit
        // for a running job). Postponing here means the update lands after the
        // manifest is written rather than on top of a half-copied bundle.
        guard owner?.gate == .holdUntilTheJobFinishes else { return false }
        owner?.installWhenTheJobFinishes(installHandler)
        return true
    }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        owner?.updateCycleFinished()
    }
}
