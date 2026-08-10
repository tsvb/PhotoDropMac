//
//  ApertureMark.swift
//  PhotoDropMac
//
//  "Pressroom" verification mark. An 8-bladed aperture iris whose blades fill
//  clockwise with the theme's marigold as bundles verify. Inspired by the
//  lens-aperture iconography of classic press-ingest tooling.
//
//  Center shows live percent during ingest; on completion the iris is fully
//  struck and stamps a marigold check.
//
//  Usage:
//      ApertureMark(progress: 0.39)              // during ingest
//          .frame(width: 52, height: 52)
//
//      ApertureMark(progress: 1, closed: true)   // completion sheet
//          .frame(width: 72, height: 72)
//

import SwiftUI

struct ApertureMark: View {
    var progress: Double
    /// On completion the iris fills fully and stamps a check in the centre.
    var closed: Bool = false
    var accent: Color = .pressroomMarigold

    private let bladeCount = 8
    /// Rotational shear that gives the blades their aperture "lean".
    private let twist = 0.20

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size: size) }
            .overlay { centerLabel }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Verification progress")
            .accessibilityValue(Text("\(Int(progress * 100)) percent"))
    }

    /// Split out of `body`, with every intermediate typed.
    ///
    /// As one expression this was marginal for the type checker: it compiled
    /// locally and failed on CI's toolchain with "unable to type-check this
    /// expression in reasonable time". Canvas closures full of unannotated
    /// `CGFloat`/`Double` arithmetic are exactly the shape that goes
    /// superlinear, and "it builds on my machine" is not a property worth
    /// keeping. Same reason `MainView`'s menu-command handlers live in their own
    /// `ViewModifier`.
    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let cx: CGFloat = size.width / 2
        let cy: CGFloat = size.height / 2
        let rOuter: CGFloat = min(size.width, size.height) / 2 - 1
        let rInner: CGFloat = rOuter * 0.40
        let oR: CGFloat = rOuter - 1.5

        // Lens barrel.
        let barrel = CGRect(x: cx - rOuter, y: cy - rOuter, width: rOuter * 2, height: rOuter * 2)
        ctx.stroke(Path(ellipseIn: barrel), with: .color(.primary.opacity(0.12)), lineWidth: 1)

        let clamped: Double = progress.clamped(to: 0...1)
        let filled: Int = closed ? bladeCount : Int((clamped * Double(bladeCount)).rounded())

        for i in 0..<bladeCount {
            let step: Double = 2 * .pi / Double(bladeCount)
            let a0: Double = Double(i) * step - .pi / 2
            let a1: Double = Double(i + 1) * step - .pi / 2

            // Each blade is a sheared wedge between the barrel (oR) and the
            // central opening (rInner); the twist on the inner edge leans the
            // blades like a real stopping-down iris.
            var blade = Path()
            blade.move(to:    point(cx: cx, cy: cy, angle: a0, radius: oR))
            blade.addLine(to: point(cx: cx, cy: cy, angle: a0 + twist, radius: rInner))
            blade.addLine(to: point(cx: cx, cy: cy, angle: a1 + twist, radius: rInner))
            blade.addLine(to: point(cx: cx, cy: cy, angle: a1, radius: oR))
            blade.closeSubpath()

            let isFilled: Bool = i < filled
            let fill: Color = isFilled ? accent.opacity(0.92) : .primary.opacity(0.07)
            let edge: Color = isFilled ? accent.opacity(0.45) : .primary.opacity(0.10)
            ctx.fill(blade, with: .color(fill))
            ctx.stroke(blade, with: .color(edge), lineWidth: 0.5)
        }
    }

    private func point(cx: CGFloat, cy: CGFloat, angle: Double, radius: CGFloat) -> CGPoint {
        CGPoint(x: cx + CGFloat(cos(angle)) * radius, y: cy + CGFloat(sin(angle)) * radius)
    }

    @ViewBuilder
    private var centerLabel: some View {
        if closed {
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(accent)
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

#Preview("Aperture sweep") {
    HStack(spacing: 16) {
        ApertureMark(progress: 0).frame(width: 56, height: 56)
        ApertureMark(progress: 0.4).frame(width: 56, height: 56)
        ApertureMark(progress: 0.75).frame(width: 56, height: 56)
        ApertureMark(progress: 1, closed: true).frame(width: 56, height: 56)
    }
    .padding()
    .background(Color.black)
}
