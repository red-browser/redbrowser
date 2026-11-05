// Builds the macOS app icon from the brand mark.
//
//   swift tools/make_icon.swift brand/png/R.png assets/AppIcon.png
//
// The brand PNG is an edge-to-edge, off-centre circle. macOS icons need the
// standard grid: an 824pt squircle tile inset 100pt on a 1024 canvas. This
// places the mark, centred on its circle, on a dark "liquid glass" tile with a
// specular top highlight and a soft drop shadow.

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: make_icon <brand.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgba(0, 0, 0, 0.45))
ctx.addPath(tilePath)
ctx.setFillColor(rgba(0.10, 0.09, 0.12, 1))
ctx.fillPath()
ctx.restoreGState()

// Glass body: deep vertical gradient
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let body = CGGradient(colorsSpace: cs, colors: [rgba(0.24, 0.22, 0.27, 1), rgba(0.07, 0.06, 0.09, 1)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(body, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// warm red glow behind the mark
let glow = CGGradient(colorsSpace: cs, colors: [rgba(0.85, 0.10, 0.16, 0.55), rgba(0.85, 0.10, 0.16, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 470, options: [])
ctx.restoreGState()

// Mark: the circle in the source spans x≈10…948, y≈38…1000 (top-left origin),
// so its centre is ≈(479, 519) with radius ≈ 470. Scale it into the tile.
let markDiameter: CGFloat = 640
let scale = markDiameter / 940
let srcCenter = CGPoint(x: 479, y: 519)
let drawW = CGFloat(srcCG.width) * scale
let drawH = CGFloat(srcCG.height) * scale
let originX = 512 - srcCenter.x * scale
let originY = 512 - (CGFloat(srcCG.height) - srcCenter.y) * scale // flip to bottom-left origin
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgba(0, 0, 0, 0.5))
ctx.draw(srcCG, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))
ctx.restoreGState()

// Specular highlight across the top half (liquid glass sheen)
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let sheen = CGGradient(colorsSpace: cs, colors: [rgba(1, 1, 1, 0.28), rgba(1, 1, 1, 0.04), rgba(1, 1, 1, 0)] as CFArray,
                       locations: [0, 0.45, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 470), options: [])
ctx.restoreGState()

// Rim light: thin inner stroke, brighter at the top
ctx.saveGState()
ctx.addPath(tilePath)
ctx.setLineWidth(5)
ctx.replacePathWithStrokedPath()
ctx.clip()
let rim = CGGradient(colorsSpace: cs, colors: [rgba(1, 1, 1, 0.55), rgba(1, 1, 1, 0.08)] as CFArray,
                     locations: [0, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
