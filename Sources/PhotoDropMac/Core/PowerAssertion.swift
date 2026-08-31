import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake for the length of an ingest.
///
/// Nothing held one, and the omission is reachable without anyone touching the
/// machine: the default idle-sleep timer on battery is ten minutes, and a card
/// offload is routinely longer than that. On sleep a bus-powered reader loses
/// power, every subsequent source read fails, and — before the source-gone halt
/// in `IngestEngine` — the job ground through the remaining bundles emitting one
/// failure line each. The user came back to hundreds of errors and no
/// explanation.
///
/// `kIOPMAssertPreventUserIdleSystemSleep` prevents *idle* sleep only. It
/// deliberately cannot defeat a lid close or an explicit Sleep, because an
/// assertion that could would be a way for a background app to hold a laptop
/// awake in a bag. The source-gone halt is what covers those; this removes the
/// case that needs no user action at all.
///
/// Released by `deinit`, so the assertion cannot outlive the job even if the
/// job throws or is cancelled — a leaked assertion is a Mac that never sleeps
/// again until reboot, which is a worse bug than the one being fixed.
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private var held = false

    /// - Parameter reason: shown to the user in `pmset -g assertions` and in
    ///   Activity Monitor's Energy tab, so it names the app and the job rather
    ///   than being an anonymous "process is preventing sleep".
    init(reason: String) {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        // Best-effort: failing to hold the assertion must never fail the copy.
        // The worst case is the behaviour that shipped before this existed.
        if result == kIOReturnSuccess {
            id = assertionID
            held = true
        }
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
    }

    deinit { release() }
}
