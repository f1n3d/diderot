// Prepares the app icon and the launch screen's logo from Design/diderot_icon.png, which shows the icon as a rounded
// tile on a dark backdrop. iOS wants the tile edge to edge and rounds it itself, so this cuts out the largest square
// just inside the tile (without its light edge), scales it and continues the tile's color into the corners. For GitHub
// it also writes the icon with transparent corners (README) and the link preview, which is uploaded by hand under
// Settings › General › Social preview (GitHub has no API for it).
//
//   swift Tools/icon/prepare-icon.swift Design/diderot_icon.png Diderot/Resources/Assets.xcassets Docs
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let source = NSImage(contentsOfFile: arguments[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    print("Usage: swift Tools/icon/prepare-icon.swift <source.png> <Assets.xcassets> <Docs>")
    exit(1)
}

/// An RGB bitmap, with transparency if asked; its rows lie top to bottom in memory.
func bitmap(width: Int, height: Int, transparent: Bool = false) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (transparent ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
    )!
}

func pixels(_ context: CGContext) -> UnsafeMutablePointer<UInt8> {
    context.data!.bindMemory(to: UInt8.self, capacity: context.width * context.height * 4)
}

// Find the tile: everything clearly greener than the neutral backdrop.
let input = bitmap(width: source.width, height: source.height)
input.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
let sourcePixels = pixels(input)
func greenness(_ p: UnsafeMutablePointer<UInt8>, _ width: Int, _ x: Int, _ y: Int) -> Int {
    let index = (y * width + x) * 4
    return Int(p[index + 1]) - max(Int(p[index]), Int(p[index + 2]))
}
var (left, right, top, bottom) = (source.width, 0, source.height, 0)
for y in 0..<source.height {
    for x in 0..<source.width where greenness(sourcePixels, source.width, x, y) > 12 {
        (left, right, top, bottom) = (min(left, x), max(right, x), min(top, y), max(bottom, y))
    }
}
// The largest square inside the tile, centered, a little in from the light edge.
let inset = 8
let side = min(right - left, bottom - top) - 2 * inset
let cropX = (left + right - side) / 2
let cropY = (top + bottom - side) / 2
let crop = source.cropping(to: CGRect(x: cropX, y: cropY, width: side, height: side))!

func render(size: Int) -> CGImage {
    let context = bitmap(width: size, height: size)
    context.interpolationQuality = .high
    context.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
    // iOS rounds the icon about as much as quarter circles of 22.5 % of its size. Outside them (the drawn rounding
    // with its light edge, the backdrop) each pixel takes the color just inside the circle in its direction, so none
    // of the drawing shows wherever iOS rounds a little less.
    let p = pixels(context)
    let original = Array(UnsafeBufferPointer(start: p, count: size * size * 4))
    let radius = Double(size) * 0.225
    let far = Double(size) - radius
    for (cx, cy) in [(radius, radius), (far, radius), (radius, far), (far, far)] {
        let xs = cx < Double(size) / 2 ? 0..<Int(cx) : Int(cx)..<size
        let ys = cy < Double(size) / 2 ? 0..<Int(cy) : Int(cy)..<size
        for y in ys {
            for x in xs {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance > radius - 3 else { continue }
                let inside = radius - 4
                let sx = min(size - 1, max(0, Int(cx + dx / distance * inside)))
                let sy = min(size - 1, max(0, Int(cy + dy / distance * inside)))
                for channel in 0..<3 { p[(y * size + x) * 4 + channel] = original[(sy * size + sx) * 4 + channel] }
            }
        }
    }
    return context.makeImage()!
}

func write(_ image: CGImage, to path: String) throws {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: path))
    print("\(image.width) × \(image.height) → \(path)")
}

/// The icon as iOS shows it: rounded, with transparent corners.
func rounded(_ icon: CGImage) -> CGImage {
    let rect = CGRect(x: 0, y: 0, width: icon.width, height: icon.height)
    let context = bitmap(width: icon.width, height: icon.height, transparent: true)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.height * 0.225, transform: nil))
    context.clip()
    context.draw(icon, in: rect)
    return context.makeImage()!
}

/// GitHub's link preview (1280 × 640): the icon beside the name and what the app is, on the icon's green.
func socialPreview() -> CGImage {
    let context = bitmap(width: 1280, height: 640)
    let icon = render(size: 400)
    // The tile's color at its top left, darker, so the icon stands out a little.
    let sample = bitmapWithImage(icon)
    let corner = pixels(sample)
    context.setFillColor(CGColor(srgbRed: CGFloat(corner[0]) / 255 * 0.8, green: CGFloat(corner[1]) / 255 * 0.8,
                                 blue: CGFloat(corner[2]) / 255 * 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1280, height: 640))
    context.draw(rounded(icon), in: CGRect(x: 110, y: 120, width: 400, height: 400))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let ink = NSColor(srgbRed: 0.95, green: 0.94, blue: 0.91, alpha: 1)
    let serif = NSFont.systemFont(ofSize: 150).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 150) }
    NSAttributedString(string: "Diderot", attributes: [.font: serif ?? NSFont.systemFont(ofSize: 150), .foregroundColor: ink])
        .draw(in: CGRect(x: 590, y: 300, width: 640, height: 190))
    NSAttributedString(string: "Native SwiftUI app for\nself-hosted Docmost", attributes: [
        .font: NSFont.systemFont(ofSize: 44), .foregroundColor: ink.withAlphaComponent(0.75),
    ]).draw(in: CGRect(x: 598, y: 150, width: 640, height: 130))
    return context.makeImage()!
}

/// A bitmap holding `image`, to read its pixels.
func bitmapWithImage(_ image: CGImage) -> CGContext {
    let context = bitmap(width: image.width, height: image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context
}

let assets = arguments[2], docs = arguments[3]
try write(render(size: 1024), to: "\(assets)/AppIcon.appiconset/icon-1024.png")
try write(render(size: 360), to: "\(assets)/AppLogo.imageset/app-logo.png")
try write(rounded(render(size: 256)), to: "\(docs)/icon.png")
try write(socialPreview(), to: "\(docs)/social-preview.png")
print("Tile \(right - left + 1) × \(bottom - top + 1) at \(left), \(top); square \(side) at \(cropX), \(cropY)")
