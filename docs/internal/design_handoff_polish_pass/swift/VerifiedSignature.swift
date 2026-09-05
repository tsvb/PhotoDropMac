//
//  VerifiedSignature.swift
//  PhotoDropMac
//
//  Compact display for an xxHash signature on a verified log row.
//  Formats a UInt64 hash as `[a3f7…7fa3]` — first four hex chars + ellipsis
//  + last four — in monospaced caption with .green tint.
//
//  Sized so a column of these lines up cleanly: ~84pt wide, tabular numbers.
//

import SwiftUI

struct VerifiedSignature: View {
    let hash: UInt64

    var body: some View {
        Text(format(hash))
            .font(.system(.caption2, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.green)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.green.opacity(0.10))
            )
            .frame(width: 84, alignment: .trailing)
            .accessibilityLabel("Verified hash signature")
            .accessibilityValue(Text(format(hash)))
    }

    private func format(_ h: UInt64) -> String {
        // 16 hex chars total; surface the first 4 and last 4.
        let hex = String(h, radix: 16, uppercase: false)
        let padded = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        let head = padded.prefix(4)
        let tail = padded.suffix(4)
        return "[\(head)…\(tail)]"
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 4) {
        VerifiedSignature(hash: 0xA3F7_8C12_45D9_7FA3)
        VerifiedSignature(hash: 0x2C91_3344_5566_77F9)
        VerifiedSignature(hash: 0xB428_9911_0011_82BB)
        VerifiedSignature(hash: 0x0000_0000_0000_00CF)
    }
    .padding()
}
