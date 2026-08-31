import Foundation

/// The update decisions that are pure logic, kept out of `SoftwareUpdater` so
/// they can be tested without launching Sparkle — and out of `Core/`, which is
/// also compiled into the headless `photodrop` tool and must not learn about an
/// update channel it does not have.

// MARK: - May an update check run at all?

/// **An ingest outranks an update.** Sparkle's job ends in replacing the running
/// application and relaunching it, and this app's job is a multi-hour copy whose
/// only safe stopping point is a file boundary — killing it anywhere else leaves
/// a half-written file that is invisible to both verify modes (see
/// `TerminationPolicy`, which makes the same call for Quit).
///
/// So checks are refused outright while a job runs, rather than allowed and then
/// made safe at install time. Refusing the *check* means the user is never shown
/// an update sheet they should not act on, which is one fewer way to arrive at
/// the dangerous state at all. The Help menu item is disabled for the same
/// reason, so in practice the refusal is invisible.
enum UpdateGate: Equatable {
    case allow
    case holdUntilTheJobFinishes

    static func decide(hasRunningJob: Bool) -> UpdateGate {
        hasRunningJob ? .holdUntilTheJobFinishes : .allow
    }

    /// Shown to the user if a check is somehow attempted anyway (a background
    /// check firing on its timer, say, which no disabled menu item can prevent).
    var refusalReason: String? {
        switch self {
        case .allow: nil
        case .holdUntilTheJobFinishes:
            "PhotoDrop is copying photos right now. It will check for updates once the ingest has finished."
        }
    }
}

// MARK: - How often

/// Deliberately the same three choices as `VerifySchedule`, in the same order.
/// Two background cadences in one app with different vocabularies is a needless
/// thing to make someone learn twice.
enum UpdateCadence: String, CaseIterable, Identifiable, Sendable {
    case daily, weekly, monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily:   "Daily"
        case .weekly:  "Weekly"
        case .monthly: "Monthly"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .daily:   86_400
        case .weekly:  604_800
        case .monthly: 2_592_000   // 30 days
        }
    }

    /// Sparkle owns the stored interval (`SUScheduledCheckInterval`), so the UI
    /// derives the selected row from that number rather than keeping a second
    /// `@AppStorage` key beside it. A stored "which cadence" key is free to
    /// contradict the interval it claims to describe — the same reasoning that
    /// makes `FolderLayout.matching` derive the selected layout from the
    /// templates instead of remembering it.
    static func closest(to interval: TimeInterval) -> UpdateCadence {
        allCases.min(by: { abs($0.seconds - interval) < abs($1.seconds - interval) }) ?? .weekly
    }
}

// MARK: - Is this build able to update at all?

/// What the built `Info.plist` says about the update channel, read back at
/// runtime.
///
/// Sparkle fails *quietly* when it is misconfigured: an absent or malformed
/// `SUPublicEDKey` produces a log line on a console nobody is reading and a
/// Check for Updates button that does nothing forever. This turns that into a
/// visible state, so a build that cannot update says so in Settings instead of
/// pretending. It is also what `SoftwareUpdater` consults before starting
/// Sparkle at all — an unconfigured build makes **no network connection**,
/// which keeps a dev build exactly as quiet as the app was before updates
/// existed.
enum UpdateConfiguration: Equatable {
    case ready(feed: URL)
    /// No `SUFeedURL` — updates were not built into this copy.
    case noFeed
    /// A feed that is not `https`. Sparkle refuses these, and so do we: an
    /// appcast over plain HTTP is an invitation to hand the user someone else's
    /// application.
    case insecureFeed(String)
    /// A feed but no `SUPublicEDKey`. Sparkle would refuse to install anything;
    /// more to the point, an unsigned update channel is a remote code execution
    /// path with the lock left off.
    case unsigned
    /// A key that is present but is not a 32-byte Ed25519 public key — a typo, a
    /// truncated copy-paste, or a DSA key pasted into the EdDSA slot.
    case malformedKey

    static func read(feedURL: String?, publicKey: String?) -> UpdateConfiguration {
        let feedString = (feedURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feedString.isEmpty else { return .noFeed }
        guard let url = URL(string: feedString), url.scheme?.lowercased() == "https", url.host != nil else {
            return .insecureFeed(feedString)
        }
        let key = (publicKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .unsigned }
        // Ed25519 public keys are exactly 32 bytes. Anything else in this slot is
        // a mistake that would otherwise surface as "updates just never work".
        guard let decoded = Data(base64Encoded: key), decoded.count == 32 else { return .malformedKey }
        return .ready(feed: url)
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var feed: URL? {
        if case .ready(let url) = self { return url }
        return nil
    }

    /// Plain-language account for Settings. Named for what the user can do about
    /// it, not for the enum case.
    var explanation: String? {
        switch self {
        case .ready:
            nil
        case .noFeed:
            "This build has no update feed, so it will never check for updates. Download new versions from the Releases page."
        case .insecureFeed(let string):
            "This build's update feed (\(string)) is not an https address, so it has been ignored. Download new versions from the Releases page."
        case .unsigned:
            "This build carries no update signing key, so updates are disabled. That is expected for a build made from source; released builds are signed. Download new versions from the Releases page."
        case .malformedKey:
            "This build's update signing key is not a valid Ed25519 key, so updates are disabled. Download new versions from the Releases page."
        }
    }
}
