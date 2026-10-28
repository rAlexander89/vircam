import AppKit
// Usage: swift scripts/make_tray_icons.swift <TrayIcon.png> <outdir>. Writes template images: on (letters + dot), off (letters only).
let src = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let rep = NSBitmapImageRep(data: src.tiffRepresentation!)!
let w = rep.pixelsWide, h = rep.pixelsHigh
var letters = [Bool](repeating: false, count: w*h), dot = letters
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w {
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    guard c.alphaComponent > 0.5 else { continue }
    let isRed = c.redComponent > 0.6 && c.greenComponent < 0.4
    let isDark = c.redComponent + c.greenComponent + c.blueComponent < 1.2
    if isRed { dot[y*w+x] = true } else if isDark { letters[y*w+x] = true } else { continue }
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
}}

let cw = maxX-minX+1, ch = maxY-minY+1
func write(_ name: String, includeDot: Bool, height: Int) {
    let scale = Double(height)/Double(ch)
    let ow = Int((Double(cw)*scale).rounded(.up))
    let full = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cw, pixelsHigh: ch, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<ch { for x in 0..<cw {
        let i = (y+minY)*w + (x+minX)
        let on = letters[i] || (includeDot && dot[i])
        full.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: on ? 1 : 0), atX: x, y: y)
    }}
    let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: ow, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
    NSGraphicsContext.current!.imageInterpolation = .high
    full.draw(in: NSRect(x: 0, y: 0, width: ow, height: height))
    NSGraphicsContext.restoreGraphicsState()
    try! small.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
for (suffix, px) in [("", 14), ("@2x", 28)] {
    write("tray-on\(suffix)", includeDot: true, height: px)
    write("tray-off\(suffix)", includeDot: false, height: px)
}
