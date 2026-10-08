// 사용법: swift make_icon.swift <출력.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1), NSColor(red: 0.08, green: 0.22, blue: 0.62, alpha: 1)])!
        .draw(in: path, angle: -90)
    // 보따리: 천으로 싼 몸통 + 위쪽 매듭(양쪽 귀) + 묶음띠
    let cx = rect.midX, base = rect.minY
    func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: x * s, y: y * s, width: w * s, height: h * s))
    }
    _ = cx; _ = base
    let cloth = NSColor(red: 0.99, green: 0.96, blue: 0.88, alpha: 1)
    let shade = NSColor(red: 0.90, green: 0.82, blue: 0.66, alpha: 1)
    // 몸통
    let body = NSBezierPath()
    body.move(to: NSPoint(x: 0.50 * s, y: 0.66 * s))
    body.curve(to: NSPoint(x: 0.20 * s, y: 0.30 * s), controlPoint1: NSPoint(x: 0.30 * s, y: 0.64 * s), controlPoint2: NSPoint(x: 0.16 * s, y: 0.48 * s))
    body.curve(to: NSPoint(x: 0.50 * s, y: 0.17 * s), controlPoint1: NSPoint(x: 0.24 * s, y: 0.20 * s), controlPoint2: NSPoint(x: 0.36 * s, y: 0.17 * s))
    body.curve(to: NSPoint(x: 0.80 * s, y: 0.30 * s), controlPoint1: NSPoint(x: 0.64 * s, y: 0.17 * s), controlPoint2: NSPoint(x: 0.76 * s, y: 0.20 * s))
    body.curve(to: NSPoint(x: 0.50 * s, y: 0.66 * s), controlPoint1: NSPoint(x: 0.84 * s, y: 0.48 * s), controlPoint2: NSPoint(x: 0.70 * s, y: 0.64 * s))
    body.close()
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.015)
    shadow.shadowBlurRadius = s * 0.03
    shadow.set()
    cloth.setFill(); body.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // 주름
    shade.setStroke()
    for (x0, y0, x1, y1, c1x, c1y) in [(0.50, 0.62, 0.34, 0.26, 0.38, 0.52), (0.50, 0.62, 0.66, 0.26, 0.62, 0.52), (0.50, 0.60, 0.50, 0.20, 0.47, 0.40)] as [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] {
        let w = NSBezierPath()
        w.lineWidth = s * 0.012
        w.move(to: NSPoint(x: x0 * s, y: y0 * s))
        w.curve(to: NSPoint(x: x1 * s, y: y1 * s), controlPoint1: NSPoint(x: c1x * s, y: c1y * s), controlPoint2: NSPoint(x: x1 * s, y: (y1 + 0.12) * s))
        w.stroke()
    }
    // 매듭의 귀 두 개
    cloth.setFill()
    for (ox, rot) in [(-0.07, 28.0), (0.07, -28.0)] as [(CGFloat, CGFloat)] {
        let ear = oval(0.50 + ox - 0.075, 0.665, 0.15, 0.085)
        var t = AffineTransform()
        t.translate(x: s * (0.50 + ox), y: s * 0.7075)
        t.rotate(byDegrees: rot)
        t.translate(x: -s * (0.50 + ox), y: -s * 0.7075)
        ear.transform(using: t)
        ear.fill()
        shade.setStroke(); ear.lineWidth = s * 0.008; ear.stroke()
    }
    // 매듭 + 띠
    let knot = oval(0.45, 0.635, 0.10, 0.085)
    NSColor(red: 0.93, green: 0.36, blue: 0.30, alpha: 1).setFill(); knot.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
