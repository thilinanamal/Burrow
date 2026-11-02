// Renders Burrow's app icon (hill + tunnel on a night sky) to an .iconset.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = s * 0.09
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [NSColor(red: 0.16, green: 0.20, blue: 0.33, alpha: 1).cgColor,
                                  NSColor(red: 0.09, green: 0.10, blue: 0.17, alpha: 1).cgColor] as CFArray,
                         locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // stars
    var seed: UInt64 = 42
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
    for _ in 0..<26 {
        let r = s * (0.003 + rnd() * 0.006)
        ctx.fillEllipse(in: CGRect(x: body.minX + rnd() * body.width, y: body.midY + rnd() * body.height * 0.5, width: r, height: r))
    }
    // moon
    let moon = CGRect(x: body.maxX - body.width * 0.33, y: body.maxY - body.height * 0.31, width: body.width * 0.15, height: body.width * 0.15)
    ctx.setFillColor(NSColor(white: 0.92, alpha: 1).cgColor); ctx.fillEllipse(in: moon)

    // hill
    let hill = CGMutablePath()
    hill.move(to: CGPoint(x: body.minX - s * 0.05, y: body.minY + body.height * 0.22))
    hill.addCurve(to: CGPoint(x: body.maxX + s * 0.05, y: body.minY + body.height * 0.22),
                  control1: CGPoint(x: body.minX + body.width * 0.25, y: body.minY + body.height * 0.82),
                  control2: CGPoint(x: body.minX + body.width * 0.75, y: body.minY + body.height * 0.82))
    hill.addLine(to: CGPoint(x: body.maxX + s * 0.05, y: body.minY - 1))
    hill.addLine(to: CGPoint(x: body.minX - s * 0.05, y: body.minY - 1))
    hill.closeSubpath()
    let soil = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 0.55, green: 0.38, blue: 0.25, alpha: 1).cgColor,
                                   NSColor(red: 0.33, green: 0.22, blue: 0.14, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.saveGState(); ctx.addPath(hill); ctx.clip()
    ctx.drawLinearGradient(soil, start: CGPoint(x: 0, y: body.minY + body.height * 0.65), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()
    // grass rim
    ctx.saveGState()
    ctx.addPath(hill); ctx.setStrokeColor(NSColor(red: 0.36, green: 0.62, blue: 0.36, alpha: 1).cgColor)
    ctx.setLineWidth(s * 0.03); ctx.strokePath()
    ctx.restoreGState()

    // tunnel entrance
    let holeW = body.width * 0.30, holeH = body.height * 0.25
    let holeX = body.midX - holeW / 2, holeY = body.minY + body.height * 0.18
    let hole = CGMutablePath()
    hole.move(to: CGPoint(x: holeX, y: holeY))
    hole.addLine(to: CGPoint(x: holeX, y: holeY + holeH - holeW / 2))
    hole.addArc(center: CGPoint(x: body.midX, y: holeY + holeH - holeW / 2), radius: holeW / 2,
                startAngle: .pi, endAngle: 0, clockwise: true)
    hole.addLine(to: CGPoint(x: holeX + holeW, y: holeY))
    hole.closeSubpath()
    ctx.addPath(hole); ctx.setFillColor(NSColor(red: 0.09, green: 0.06, blue: 0.05, alpha: 1).cgColor); ctx.fillPath()
    // warm light inside
    ctx.setFillColor(NSColor(red: 1, green: 0.78, blue: 0.4, alpha: 0.9).cgColor)
    ctx.fillEllipse(in: CGRect(x: body.midX - holeW * 0.12, y: holeY + holeH * 0.25, width: holeW * 0.24, height: holeW * 0.24))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
