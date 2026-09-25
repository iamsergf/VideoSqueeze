import AppKit
let out = CommandLine.arguments[1]
for (name, px) in [("16",16),("16@2x",32),("32",32),("32@2x",64),("128",128),("128@2x",256),("256",256),("256@2x",512),("512",512),("512@2x",1024)] {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
        let inset = s * 0.1
        let rect = r.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
        NSGradient(colors: [NSColor(red: 0.35, green: 0.3, blue: 0.95, alpha: 1),
                            NSColor(red: 0.9, green: 0.3, blue: 0.6, alpha: 1)])!.draw(in: path, angle: -60)
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        if let sym = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let tinted = NSImage(size: sym.size, flipped: false) { rr in
                sym.draw(in: rr); NSColor.white.set(); rr.fill(using: .sourceAtop); return true }
            tinted.draw(in: NSRect(x: (s - sym.size.width)/2, y: (s - sym.size.height)/2, width: sym.size.width, height: sym.size.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
