#!/usr/bin/env swift
//
// make-icon.swift — generate AppIcon.appiconset for PhotoDropMac.
//
// Run:  swift scripts/make-icon.swift [outputDir]
// Default outputDir: Sources/PhotoDropMac/Assets.xcassets/AppIcon.appiconset
//
// The icon is generated, not hand-drawn, so the geometry below IS the source of
// truth — re-run this after editing it rather than touching the PNGs.
//
// ── Why these numbers ────────────────────────────────────────────────────────
// macOS icons since Big Sur live "in the squircle": every app icon is the same
// rounded-square silhouette at the same size, so a row of them in the Dock reads
// as one family. Apple's template puts that silhouette at 824×824 inside a
// 1024×1024 canvas — the 100pt margin on each side is not padding to fill, it is
// reserved space that the shadow occupies and that keeps this icon optically the
// same size as every other app's. Drawing to the canvas edge makes an icon look
// oversized and out of place next to its neighbours.
//
// The corner is a *continuous* curve (Apple's squircle), not a circular arc. The
// difference is subtle at 1024 and obvious in a Dock line-up — a circular-corner
// icon reads as slightly "pinched" at the corners. Rather than approximate it
// with béziers, the mask is rendered from a CALayer with `cornerCurve =
// .continuous`, which is the same shape AppKit itself draws.

import AppKit
import QuartzCore

// ── Grid (Apple macOS app icon template, 1024pt canvas) ─────────────────────
let canvas: CGFloat = 1024
let body: CGFloat = 824              // the squircle itself
let bodyOrigin = (canvas - body) / 2 // 100pt margin all round
let cornerRadius: CGFloat = 185.4    // continuous curve

// ── Palette ─────────────────────────────────────────────────────────────────
// Ultramarine, the app's own "ledger" ink (#120A8F), lifted into a gradient so
// the shape reads with some depth at large sizes.
func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}
let gradientTop = rgb(0x4A, 0x3D, 0xEA)
let gradientBottom = rgb(0x12, 0x0A, 0x8F)

/// The squircle silhouette as an alpha mask, straight from Core Animation.
func squircleMask() -> CGImage {
    let layer = CALayer()
    layer.frame = CGRect(x: 0, y: 0, width: body, height: body)
    layer.cornerRadius = cornerRadius
    layer.cornerCurve = .continuous
    layer.backgroundColor = CGColor(gray: 1, alpha: 1)
    layer.isOpaque = false

    let ctx = CGContext(data: nil, width: Int(body), height: Int(body),
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    layer.render(in: ctx)
    return ctx.makeImage()!
}

/// A memory card: rounded rectangle with the chamfered top-left corner that
/// makes an SD card instantly recognizable even as a silhouette.
func cardPath(in rect: CGRect, corner: CGFloat, chamfer: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX, y: rect.maxY - chamfer))
    p.addLine(to: CGPoint(x: rect.minX + chamfer, y: rect.maxY))          // the notch
    p.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.maxY))
    p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
             tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - corner), radius: corner)
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + corner))
    p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
             tangent2End: CGPoint(x: rect.maxX - corner, y: rect.minY), radius: corner)
    p.addLine(to: CGPoint(x: rect.minX + corner, y: rect.minY))
    p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
             tangent2End: CGPoint(x: rect.minX, y: rect.minY + corner), radius: corner)
    p.closeSubpath()
    return p
}

/// Downward arrow — a tapered head plus a stem, drawn as one filled shape so it
/// stays a single solid mass when it is only a few pixels tall.
func arrowPath(cx: CGFloat, top: CGFloat, bottom: CGFloat,
               headWidth: CGFloat, stemWidth: CGFloat, headHeight: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let shoulder = bottom + headHeight
    p.move(to: CGPoint(x: cx - stemWidth / 2, y: top))
    p.addLine(to: CGPoint(x: cx + stemWidth / 2, y: top))
    p.addLine(to: CGPoint(x: cx + stemWidth / 2, y: shoulder))
    p.addLine(to: CGPoint(x: cx + headWidth / 2, y: shoulder))
    p.addLine(to: CGPoint(x: cx, y: bottom))
    p.addLine(to: CGPoint(x: cx - headWidth / 2, y: shoulder))
    p.addLine(to: CGPoint(x: cx - stemWidth / 2, y: shoulder))
    p.closeSubpath()
    return p
}

/// How much detail the glyph carries.
///
/// Apple's guidance is to draw each size, not to scale one master down: detail
/// that reads at 512pt turns to grey mush at 16pt. `compact` is used for the
/// 16pt and 32pt slots, where it drops the contact stripes and the inner
/// shadows and — crucially — closes the gap between card and arrow so the glyph
/// is a single connected mass. At 16pt that gap is one pixel row and reads as
/// noise, splitting the mark into two anonymous blobs.
///
/// The squircle grid is identical in both: only the artwork inside changes.
enum Detail { case full, compact }

func renderIcon(_ detail: Detail = .full) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas),
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let mask = squircleMask()
    let bodyRect = CGRect(x: bodyOrigin, y: bodyOrigin, width: body, height: body)

    // Shadow: cast by drawing the silhouette once with a shadow set, before the
    // real artwork goes on top. This is what the 100pt margin is reserved for.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                  color: CGColor(gray: 0, alpha: 0.30))
    ctx.draw(mask, in: bodyRect)
    ctx.restoreGState()

    // Everything from here is clipped to the squircle — nothing escapes the jail.
    ctx.saveGState()
    ctx.clip(to: bodyRect, mask: mask)

    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [gradientTop, gradientBottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: canvas - bodyOrigin),
                           end: CGPoint(x: 0, y: bodyOrigin),
                           options: [])

    // A soft highlight across the top third keeps the large sizes from looking
    // like flat vector art. Omitted when compact: at 16pt it only muddies the
    // contrast between glyph and background.
    if detail == .full {
        let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [CGColor(gray: 1, alpha: 0.16),
                                        CGColor(gray: 1, alpha: 0)] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(sheen,
                               start: CGPoint(x: 0, y: canvas - bodyOrigin),
                               end: CGPoint(x: 0, y: canvas * 0.52),
                               options: [])
    }

    // ── Glyph ───────────────────────────────────────────────────────────────
    // A memory card above a downward arrow: the card is the source, the arrow is
    // the drop. Two shapes only — at 16pt anything more turns to mush.
    // The glyph is sized to leave ~140pt of squircle visible above the card and
    // below the arrow tip. Filling the squircle edge-to-edge is the classic
    // mistake: it makes the icon look larger and louder than its neighbours in
    // the Dock, which is precisely the consistency the shared silhouette buys.
    let cx = canvas / 2
    // The card is deliberately narrower than the arrowhead below it. At 16pt the
    // stripes and the notch are gone and only the silhouette survives, so the
    // shapes have to differ in *width* — two similar-width stacked blocks blur
    // into an anonymous vertical bar, while narrow-over-wide stays legible.
    let cardW: CGFloat = detail == .full ? 200 : 230
    let cardH: CGFloat = detail == .full ? 250 : 215
    let cardY: CGFloat = detail == .full ? 509 : 530
    let cardRect = CGRect(x: cx - cardW / 2, y: cardY, width: cardW, height: cardH)

    // The card is a large-size detail only. Keeping it at 16/32pt — even fused
    // to the arrow — produced a narrow rounded block over a wide flare, which
    // reads as a person/bust silhouette rather than a memory card. Dropping it
    // entirely leaves an unambiguous arrow, which is the honest thing to show at
    // a size where "photo" cannot be conveyed anyway.
    if detail == .full {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18,
                      color: CGColor(gray: 0, alpha: 0.22))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(cardPath(in: cardRect, corner: 26, chamfer: 62))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Contact stripes — reads as "memory card" at 128pt+, and would only be grey
    // sludge below that, so compact drops them entirely.
    if detail == .full {
        ctx.setFillColor(gradientBottom.copy(alpha: 0.30)!)
        let stripeW: CGFloat = 22, stripeH: CGFloat = 68, gap: CGFloat = 18
        let stripeTotal = stripeW * 4 + gap * 3
        for i in 0..<4 {
            let x = cx - stripeTotal / 2 + CGFloat(i) * (stripeW + gap)
            let r = CGRect(x: x, y: cardRect.minY + 30, width: stripeW, height: stripeH)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 9, cornerHeight: 9, transform: nil))
        }
        ctx.fillPath()
    }

    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    if detail == .full {
        ctx.addPath(arrowPath(cx: cx, top: 464, bottom: 264,
                              headWidth: 290, stemWidth: 80, headHeight: 110))
    } else {
        // Sole element at 16/32pt, so it takes the full glyph area.
        ctx.addPath(arrowPath(cx: cx, top: 745, bottom: 279,
                              headWidth: 360, stemWidth: 130, headHeight: 175))
    }
    ctx.fillPath()

    ctx.restoreGState()
    return ctx.makeImage()!
}

// ── Emit the iconset ────────────────────────────────────────────────────────
func write(_ image: CGImage, size: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let out = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "Sources/PhotoDropMac/Assets.xcassets/AppIcon.appiconset")
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let masterFull = renderIcon(.full)
let masterCompact = renderIcon(.compact)

/// 32px and below get the simplified glyph. 32 is the crossover because both
/// 16@2x and 32@1x land there, and the full glyph's stripes and card/arrow gap
/// stop resolving at that point.
func master(forPixels px: Int) -> CGImage { px <= 32 ? masterCompact : masterFull }

// (idiom point, scale) → the ten PNGs macOS wants.
let variants: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
var images: [[String: String]] = []
for v in variants {
    let px = v.pt * v.scale
    let name = "icon_\(v.pt)x\(v.pt)\(v.scale == 2 ? "@2x" : "").png"
    write(master(forPixels: px), size: px, to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(v.pt)x\(v.pt)",
                   "scale": "\(v.scale)x", "filename": name])
}

let contents: [String: Any] = [
    "images": images,
    "info": ["version": 1, "author": "make-icon.swift"],
]
let json = try! JSONSerialization.data(withJSONObject: contents,
                                       options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))

print("✓ Wrote \(variants.count) PNGs + Contents.json to \(outDir.path)")
