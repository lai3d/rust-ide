// Renders the RustIDE app icon and builds Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS-style rounded square in rust orange, light to deep.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSShadow().apply { $0.shadowColor = .black.withAlphaComponent(0.3); $0.shadowBlurRadius = 30; $0.shadowOffset = NSSize(width: 0, height: -12) }
NSGradient(starting: NSColor(red: 0.96, green: 0.55, blue: 0.27, alpha: 1),
           ending: NSColor(red: 0.62, green: 0.20, blue: 0.08, alpha: 1))!.draw(in: shape, angle: -90)
NSShadow().apply { $0.shadowColor = nil }

// "Rs" plus a terminal-style underscore cursor: "Rs_".
let font = NSFont.systemFont(ofSize: 380, weight: .black)
let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 380) } ?? font
let text = NSAttributedString(string: "Rs", attributes: [.font: rounded, .foregroundColor: NSColor.white])
let textSize = text.size()
let cursorWidth: CGFloat = 130, gap: CGFloat = 26
let origin = NSPoint(x: (size - textSize.width - gap - cursorWidth) / 2, y: (size - textSize.height) / 2 + 10)
text.draw(at: origin)
NSColor(red: 1, green: 0.88, blue: 0.75, alpha: 0.95).setFill()
NSBezierPath(roundedRect: NSRect(x: origin.x + textSize.width + gap, y: origin.y + rounded.descender.magnitude * 0.55,
                                 width: cursorWidth, height: 46), xRadius: 14, yRadius: 14).fill()
image.unlockFocus()

extension NSShadow {
    func apply(_ configure: (NSShadow) -> Void) { configure(self); set() }
}

// Write the iconset and convert.
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let output = URL(fileURLWithPath: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
