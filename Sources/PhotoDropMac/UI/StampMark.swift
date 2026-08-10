//
//  StampMark.swift
//  PhotoDropMac
//
//  Direction-B verification mark. A 24-tick ring that fills clockwise.
//  Used when VerificationStyle is .ledger. Otherwise SealGrid is shown.
//
//  Center shows live percent during ingest; stamps with the accent-coloured
//  check on completion.
//
//  Usage:
//      StampMark(progress: 0.62)            // during ingest
//          .frame(width: 88, height: 88)
//
//      StampMark(progress: 1, stamped: true)  // completion sheet
//          .frame(width: 72, height: 72)
//

import SwiftUI

struct StampMark: View {
    var progress: Double
    /// On completion the ring fills + stamps a check in the centre.
    var stamped: Bool = false
    /// Fill colour for verified ticks and the stamp. Defaults to the system
    /// accent; callers pass the active theme's resolved accent.
    var accent: Color = .accentColor

    private let tickCount = 24

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size: size) }
            .overlay { centerLabel }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Verification progress")
            .accessibilityValue(Text("\(Int(progress * 100)) percent"))
    }

    /// Split out of `body` with every intermediate annotated — see the note in
    /// `ApertureMark.draw`. CI (Xcode 16.4 / Swift 6.1.2) refuses to type-check
    /// these Canvas closures in reasonable time while the local toolchain
    /// (26.6 / 6.3.3) finishes them without complaint, so "it builds here" says
    /// nothing about whether it builds.
    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let cx: CGFloat = size.width / 2
        let cy: CGFloat = size.height / 2
        let rOuter: CGFloat = min(size.width, size.height) / 2 - 1
        let rInner: CGFloat = rOuter - 4.5

        // Faint outer hairline + inner hairline.
        let outer = CGRect(x: cx - rOuter, y: cy - rOuter, width: rOuter * 2, height: rOuter * 2)
        let inner = CGRect(x: cx - rInner, y: cy - rInner, width: rInner * 2, height: rInner * 2)
        ctx.stroke(Path(ellipseIn: outer), with: .color(.primary.opacity(0.10)), lineWidth: 0.75)
        ctx.stroke(Path(ellipseIn: inner), with: .color(.primary.opacity(0.06)), lineWidth: 0.5)

        let clamped: Double = progress.clamped(to: 0...1)
        let filled: Int = Int((clamped * Double(tickCount)).rounded())
        let t1: CGFloat = rOuter - 1
        let t2: CGFloat = rInner + 1

        for i in 0..<tickCount {
            let angle: Double = Double(i) / Double(tickCount) * 2 * .pi - .pi / 2
            let dx: CGFloat = CGFloat(cos(angle))
            let dy: CGFloat = CGFloat(sin(angle))

            var path = Path()
            path.move(to: CGPoint(x: cx + dx * t1, y: cy + dy * t1))
            path.addLine(to: CGPoint(x: cx + dx * t2, y: cy + dy * t2))

            let isFilled: Bool = i < filled
            let colour: Color = isFilled ? accent : .primary.opacity(0.08)
            let width: CGFloat = isFilled ? 1.6 : 1
            ctx.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    @ViewBuilder
    private var centerLabel: some View {
        if stamped {
            // Stamped check, drawn with accent-tinted disk + heavy check.
            ZStack {
                Circle()
                    .fill(accent.opacity(0.10))
                    .padding(8)
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(accent)
            }
        } else {
            Text("\(Int(progress * 100))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

#Preview("Progress sweep") {
    HStack(spacing: 16) {
        StampMark(progress: 0).frame(width: 56, height: 56)
        StampMark(progress: 0.4).frame(width: 56, height: 56)
        StampMark(progress: 0.75).frame(width: 56, height: 56)
        StampMark(progress: 1, stamped: true).frame(width: 56, height: 56)
    }
    .padding()
    .tint(Color(red: 18/255, green: 10/255, blue: 143/255)) // Ultramarine
}
