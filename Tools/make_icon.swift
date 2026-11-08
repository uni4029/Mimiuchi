import AppKit
import CoreGraphics

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt rounded rect centered, corner radius ~185.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Shadow + gradient background.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(squircle)
ctx.setFillColor(NSColor(red: 0.05, green: 0.27, blue: 0.53, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let colors = [NSColor(red: 0.10, green: 0.45, blue: 0.82, alpha: 1).cgColor,
              NSColor(red: 0.03, green: 0.20, blue: 0.45, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// Subtle top highlight.
ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
ctx.fillEllipse(in: CGRect(x: rect.minX - 200, y: rect.midY + 60, width: rect.width + 400, height: rect.height))
ctx.restoreGState()

// Two overlapping speech bubbles.
func bubble(_ r: CGRect, tailLeft: Bool, color: NSColor) {
    let path = CGMutablePath()
    path.addRoundedRect(in: r, cornerWidth: 70, cornerHeight: 70)
    let tx = tailLeft ? r.minX + 90 : r.maxX - 90
    path.move(to: CGPoint(x: tx - 34, y: r.minY + 2))
    path.addLine(to: CGPoint(x: tx + (tailLeft ? -60 : 60), y: r.minY - 70))
    path.addLine(to: CGPoint(x: tx + 34, y: r.minY + 2))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}
bubble(CGRect(x: 205, y: 430, width: 400, height: 330), tailLeft: true, color: .white)
bubble(CGRect(x: 430, y: 285, width: 390, height: 320), tailLeft: false, color: NSColor(red: 0.55, green: 0.80, blue: 1.0, alpha: 1))

func draw(_ text: String, font: NSFont, color: NSColor, center: CGPoint) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let s = NSAttributedString(string: text, attributes: attrs)
    let b = s.size()
    s.draw(at: CGPoint(x: center.x - b.width / 2, y: center.y - b.height / 2))
}
draw("文", font: NSFont(name: "HiraginoSans-W7", size: 210) ?? .boldSystemFont(ofSize: 210),
     color: NSColor(red: 0.05, green: 0.27, blue: 0.53, alpha: 1), center: CGPoint(x: 405, y: 600))
draw("A", font: .systemFont(ofSize: 220, weight: .heavy),
     color: NSColor(red: 0.03, green: 0.20, blue: 0.45, alpha: 1), center: CGPoint(x: 625, y: 440))

image.unlockFocus()
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")
