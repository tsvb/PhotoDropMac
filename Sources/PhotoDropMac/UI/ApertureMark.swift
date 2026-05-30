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
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let rOuter = min(size.width, size.height) / 2 - 1
            let rInner = rOuter * 0.40

            // Lens barrel.
            ctx.stroke(
                Path(ellipseIn: CGRect(
                    x: cx - rOuter, y: cy - rOuter,
                    width: rOuter * 2, height: rOuter * 2
                )),
                with: .color(.primary.opacity(0.12)),
                lineWidth: 1
            )

            let filled = closed
                ? bladeCount
                : Int((progress.clamped(to: 0...1) * Double(bladeCount)).rounded())

            let oR = rOuter - 1.5
            for i in 0..<bladeCount {
                let a0 = Double(i)     / Double(bladeCount) * 2 * .pi - .pi / 2
                let a1 = Double(i + 1) / Double(bladeCount) * 2 * .pi - .pi / 2

                // Each blade is a sheared wedge between the barrel (oR) and the
                // central opening (rInner); the twist on the inner edge leans
                // the blades like a real stopping-down iris.
                var blade = Path()
                blade.move(to:    CGPoint(x: cx + cos(a0)         * oR,     y: cy + sin(a0)         * oR))
                blade.addLine(to: CGPoint(x: cx + cos(a0 + twist) * rInner, y: cy + sin(a0 + twist) * rInner))
                blade.addLine(to: CGPoint(x: cx + cos(a1 + twist) * rInner, y: cy + sin(a1 + twist) * rInner))
                blade.addLine(to: CGPoint(x: cx + cos(a1)         * oR,     y: cy + sin(a1)         * oR))
                blade.closeSubpath()

                let isFilled = i < filled
                ctx.fill(
                    blade,
                    with: .color(isFilled ? accent.opacity(0.92) : .primary.opacity(0.07))
                )
                ctx.stroke(
                    blade,
                    with: .color(isFilled ? accent.opacity(0.45) : .primary.opacity(0.10)),
                    lineWidth: 0.5
                )
            }
        }
        .overlay {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Verification progress")
        .accessibilityValue(Text("\(Int(progress * 100)) percent"))
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
