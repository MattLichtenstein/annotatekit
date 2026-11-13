// Renders Annotate Inbox's app icon: a white paper plane rising out of an inbox tray on a blue
// rounded square, following the macOS icon grid. Usage: swift make-icon.swift <output.png>
// To regenerate the committed AppIcon.icns beside this script, render the 1024-pixel master,
// resize it with `sips` into an AppIcon.iconset (16–512 at 1x and 2x), then run
// `iconutil -c icns AppIcon.iconset -o tools/mac-inbox/AppIcon.icns`.
import AppKit

let canvas: CGFloat = 1024
// macOS grid: an 824-point body centered on the 1024 canvas, leaving room for the system shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }
    let shape = NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius)

    // Soft drop shadow beneath the body, as on system icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor(srgbRed: 0.04, green: 0.40, blue: 0.92, alpha: 1).setFill()
    shape.fill()
    context.restoreGState()

    // Blue gradient body, lighter at the top.
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.66, blue: 1.00, alpha: 1),
                        NSColor(srgbRed: 0.02, green: 0.42, blue: 0.95, alpha: 1)])?.draw(in: shape, angle: -90)

    // A faint top sheen and a hairline edge give the surface some depth.
    context.saveGState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])?
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    context.restoreGState()
    NSColor.white.withAlphaComponent(0.22).setStroke()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: cornerRadius - 2, yRadius: cornerRadius - 2)
    edge.lineWidth = 4
    edge.stroke()

    func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [.white]))
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        // Fit the glyph's aspect ratio inside the target rect.
        let scale = min(rect.width / glyph.size.width, rect.height / glyph.size.height)
        let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor(srgbRed: 0, green: 0.15, blue: 0.45, alpha: 0.35).cgColor)
        glyph.draw(in: NSRect(origin: origin, size: size))
        context.restoreGState()
    }

    // The tray sits low; the plane rises out of it toward the top right.
    symbol("tray", pointSize: 400, weight: .semibold, in: NSRect(x: 232, y: 214, width: 560, height: 330))
    symbol("paperplane.fill", pointSize: 300, weight: .semibold, in: NSRect(x: 396, y: 500, width: 300, height: 300))
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
