// Draws the app icon: the Monitor's eye on the Field accent. Run by build-app.sh; writes a 1024 px PNG.
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset = size * 0.1
let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let accent = NSColor(srgbRed: 0x44 / 255.0, green: 0x53 / 255.0, blue: 0xC9 / 255.0, alpha: 1)
let bright = NSColor(srgbRed: 0x5B / 255.0, green: 0x6B / 255.0, blue: 0xE0 / 255.0, alpha: 1)
NSGradient(starting: bright, ending: accent)!.draw(in: NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18), angle: -90)
let c = NSPoint(x: size / 2, y: size / 2)
NSColor.white.setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 250, y: c.y - 250, width: 500, height: 500))
ring.lineWidth = 56
ring.stroke()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: c.x - 92, y: c.y - 92, width: 184, height: 184)).fill()
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
