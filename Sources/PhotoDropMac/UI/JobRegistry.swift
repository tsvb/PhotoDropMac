import Foundation
import Observation

/// The one place to ask "is a copy in flight right now?".
///
/// The app delegate owns no view state, and the copier lives in the scene, so
/// without this there is no way for `applicationShouldTerminate` to know a job
/// is running — which is why Quit went straight to `NSApp.terminate(nil)` and
/// took whatever was mid-write with it. Weak, so a finished or discarded copier
/// can never hold the app open.
@MainActor
@Observable
final class JobRegistry {
    weak var runningCopier: Copier?
}

/// What to do about a quit request. Pure, so the decision is testable without an
/// `NSApplication`.
enum TerminationPolicy {
    enum Decision: Equatable {
        case quitNow
        /// Cancel the job, let the engine write its manifest and log, and reply
        /// to the terminate request when it has. A killed process skips
        /// `FileCopier`'s partial cleanup, and the orphan it leaves is invisible
        /// to both verify modes forever.
        case waitForTheJobToStop
    }

    static func decide(hasRunningJob: Bool) -> Decision {
        hasRunningJob ? .waitForTheJobToStop : .quitNow
    }
}

/// Whether a change in mounted cards should raise the main window.
///
/// The observer lives on the `MenuBarExtra` label, and in `.withCard` mode that
/// label is *created by* the drives-empty→non-empty transition it needs to
/// observe. Without an initial delivery the first card of a session never fired
/// it, so the setting was inert in the one mode where it matters most — and
/// inert in `.hidden` too, where there is no menu bar to host the observer at
/// all, while Settings showed the toggle plainly enabled in all three.
enum MenuBarAutoOpen {
    static func shouldOpen(previous: [DetectedDrive.ID], current: [DetectedDrive.ID], isInitial: Bool) -> Bool {
        // On the initial delivery there is no "before": the observer exists
        // because a card is present, so a present card is the arrival.
        if isInitial { return !current.isEmpty }
        return !Set(current).subtracting(Set(previous)).isEmpty
    }

    /// The menu bar is the host that detects arrivals; without it the toggle can
    /// do nothing. Settings disables it rather than lying about it.
    static func isAvailable(for visibility: MenuBarVisibility) -> Bool {
        visibility != .hidden
    }
}

/// Which card stays selected when the set of mounted cards changes.
///
/// This lived as an if/else-if inside an `.onChange` closure in `MainView.body`
/// — a rule with three cases and no test, in the one place a test could not
/// reach it. (It was also, measurably, one of the two expressions the type
/// checker still spent real time on there.)
enum DriveSelection {
    static func reconcile(current: DetectedDrive.ID?, drives: [DetectedDrive.ID]) -> DetectedDrive.ID? {
        // Keep the user's choice while that card is still mounted: inserting a
        // second card must not move the selection out from under them.
        if let current, drives.contains(current) { return current }
        return drives.first
    }
}
