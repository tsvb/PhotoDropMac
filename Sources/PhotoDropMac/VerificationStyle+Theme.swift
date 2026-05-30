//
//  VerificationStyle+Theme.swift
//  PhotoDropMac
//
//  SwiftUI-facing theming for VerificationStyle. The enum itself
//  (AppCoordinator.swift) stays UI-free; the visual identity of each theme
//  lives here and is applied together at the app root (PhotoDropMacApp).
//
//  Each theme commits to a full look — accent, typography, and appearance —
//  rather than just recolouring the system app:
//
//    • Steady    — the system look. Your accent, your light/dark, SF Pro.
//    • Ledger    — editorial: light "paper", serif type, ultramarine ink.
//    • Pressroom — wire desk: dark, monospaced type, marigold accent.
//

import SwiftUI

extension VerificationStyle {
    /// Theme accent, applied via `.tint(_:)` at the app root so standard
    /// controls follow it. `nil` for Steady — it defers to the system accent.
    var accent: Color? {
        switch self {
        case .steady:    return nil
        case .ledger:    return .ledgerUltramarine
        case .pressroom: return .pressroomMarigold
        }
    }

    /// Non-optional accent for views that set an explicit foreground colour —
    /// icons drawn with `Color.accentColor` and the verification marks, which
    /// do not follow `.tint`. Resolves to the theme colour, or the system
    /// accent when the theme defers to it (Steady).
    var resolvedAccent: Color { accent ?? .accentColor }

    /// App-wide typography voice, applied via `.fontDesign` at the root.
    /// Ledger is serif (editorial), Pressroom is monospaced (wire desk),
    /// Steady follows the system (`nil`).
    var fontDesign: Font.Design? {
        switch self {
        case .steady:    return nil
        case .ledger:    return .serif
        case .pressroom: return .monospaced
        }
    }

    /// Forced appearance, applied via `.preferredColorScheme` at the root.
    /// A ledger is paper (light); a darkroom / wire desk is dark. Steady
    /// follows the user's system setting (`nil`).
    var colorScheme: ColorScheme? {
        switch self {
        case .steady:    return nil
        case .ledger:    return .light
        case .pressroom: return .dark
        }
    }
}

extension Color {
    /// Warm marigold used by the Pressroom theme — inspired by the amber of
    /// classic press-ingest tooling. Reads clearly on the dark wire-desk UI.
    static let pressroomMarigold = Color(red: 0.91, green: 0.62, blue: 0.16)

    /// Deep ultramarine ink for the Ledger theme — the colour the original
    /// design handoff rendered with (#120A8F). Reads as ink on light paper.
    static let ledgerUltramarine = Color(red: 18 / 255, green: 10 / 255, blue: 143 / 255)
}
