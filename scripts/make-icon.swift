// Draws the app icon (1024px) — run by build-app.sh, output fed to iconutil.
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.19, alpha: 1),
           ending: NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.08, alpha: 1))!.draw(in: bg, angle: -90)

// Two gauges: Claude (warm) and Codex (cool)
let gauges: [(CGFloat, NSColor)] = [(0.68, NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)),
                                    (0.42, NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.98, alpha: 1))]
let gw: CGFloat = 170, gh: CGFloat = 560, gap: CGFloat = 90
var x = size / 2 - gw - gap / 2
for (fill, color) in gauges {
    let r = NSRect(x: x, y: (size - gh) / 2, width: gw, height: gh)
    let track = NSBezierPath(roundedRect: r, xRadius: gw / 2, yRadius: gw / 2)
    NSColor.white.withAlphaComponent(0.12).setFill(); track.fill()
    NSGraphicsContext.saveGraphicsState(); track.addClip()
    color.setFill(); NSRect(x: r.minX, y: r.minY, width: gw, height: gh * fill).fill()
    NSGraphicsContext.restoreGraphicsState()
    x += gw + gap
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
