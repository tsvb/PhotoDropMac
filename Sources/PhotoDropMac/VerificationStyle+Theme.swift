//
//  VerificationStyle+Theme.swift
//  PhotoDropMac
//
//  SwiftUI-facing theming for VerificationStyle. The enum itself
//  (AppCoordinator.swift) stays UI-free; the per-theme accent lives here so a
//  named theme can bring its own colour while Steady/Ledger keep following the
//  user's system accent.
//

import SwiftUI

extension VerificationStyle {
    /// The theme accent, applied via `.tint(_:)` to the verification surfaces
    /// (progress bar, completion button, the mark). `nil` means "follow the
    /// system accent" — the documented default for Steady and Ledger. Pressroom
    /// brings its own warm marigold, because that colour *is* its identity.
    var accent: Color? {
        switch self {
        case .pressroom:       return .pressroomMarigold
        case .steady, .ledger: return nil
        }
    }

    /// Non-optional accent for views that set an explicit foreground colour —
    /// icons drawn with `Color.accentColor`, which does not follow `.tint`.
    /// Resolves to the theme colour, or the system accent when the theme
    /// defers to it (Steady, Ledger).
    var resolvedAccent: Color { accent ?? .accentColor }
}

extension Color {
    /// Warm marigold used by the Pressroom theme — inspired by the amber of
    /// classic press-ingest tooling. Reads clearly on the dark progress UI.
    static let pressroomMarigold = Color(red: 0.91, green: 0.62, blue: 0.16)
}
