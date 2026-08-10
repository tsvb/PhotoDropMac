//
//  SealGrid.swift
//  PhotoDropMac
//
//  Custom verification mark — a 4×4 grid where each cell fills in row-major
//  order as `progress` advances from 0 to 1. Replaces `checkmark.seal.fill`
//  in the progress pane and completion sheet.
//
//  Drawing uses Canvas { } so the whole mark is one render command per frame.
//  No images, no SF Symbols.
//
//  Usage:
//      SealGrid(progress: progress.fraction)
//          .frame(width: 64, height: 64)
//
//      SealGrid(progress: 1, pulse: true)   // completion sheet
//          .frame(width: 56, height: 56)
//

import SwiftUI

struct SealGrid: View {
    /// 0...1. Cells fill in row-major order in proportion to this.
    var progress: Double
    /// If true, the last cell does a single scale pulse on appear.
    /// Use on the completion sheet; do not toggle during ingest.
    var pulse: Bool = false
    /// Fill colour for verified cells. Defaults to the system accent; callers
    /// pass the active theme's resolved accent.
    var accent: Color = .accentColor

    private let columns = 4
    private let rows = 4
    private let cellGap: CGFloat = 2
    private let pad: CGFloat = 2

    @State private var pulseScale: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size: size) }
        .scaleEffect(pulse ? pulseScale : 1)
        .onAppear {
            guard pulse else { return }
            // Single, snappy "stamped" pulse on completion. No loop.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                pulseScale = 1.06
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.65)) {
                    pulseScale = 1
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Verification progress")
        .accessibilityValue(Text("\(Int(progress * 100)) percent"))
    }

    /// Split out of `body` with every intermediate annotated — see the note in
    /// `ApertureMark.draw`. The CI toolchain (Xcode 16.4 / Swift 6.1.2) will not
    /// type-check these mixed `CGFloat`/`Double`/`Int` Canvas closures in
    /// reasonable time, while the local one (26.6 / 6.3.3) does; a green build
    /// here is not evidence of a green build anywhere else.
    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let totalCells: Int = columns * rows
        let clamped: Double = progress.clamped(to: 0...1)
        let filled: Int = Int((clamped * Double(totalCells)).rounded())

        let usableWidth: CGFloat = size.width - pad * 2
        let usableHeight: CGFloat = size.height - pad * 2
        let cellW: CGFloat = (usableWidth - cellGap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellH: CGFloat = (usableHeight - cellGap * CGFloat(rows - 1)) / CGFloat(rows)

        // Background frame (very faint, gives the grid edge presence).
        let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6)
        ctx.fill(bg, with: .color(.primary.opacity(0.04)))

        for i in 0..<totalCells {
            let row: Int = i / columns
            let col: Int = i % columns
            let x: CGFloat = pad + CGFloat(col) * (cellW + cellGap)
            let y: CGFloat = pad + CGFloat(row) * (cellH + cellGap)

            let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
            let path = Path(roundedRect: rect, cornerRadius: 1.5)
            let colour: Color = i < filled ? accent : .primary.opacity(0.10)
            ctx.fill(path, with: .color(colour))
        }
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

// MARK: - Previews

#Preview("Progress sweep") {
    HStack(spacing: 16) {
        SealGrid(progress: 0).frame(width: 56, height: 56)
        SealGrid(progress: 0.25).frame(width: 56, height: 56)
        SealGrid(progress: 0.5).frame(width: 56, height: 56)
        SealGrid(progress: 0.75).frame(width: 56, height: 56)
        SealGrid(progress: 1, pulse: true).frame(width: 56, height: 56)
    }
    .padding()
    .tint(Color(red: 18/255, green: 10/255, blue: 143/255)) // Ultramarine
}
