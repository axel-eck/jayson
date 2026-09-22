// Renders the recoloured logo onto a macOS-style rounded tile at every iconset size.
// usage: swift Scripts/RenderIcon.swift <mark.svg> <out.iconset> [tileHex]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: RenderIcon <mark.svg> <out.iconset> [tileHex]\n".data(using: .utf8)!)
    exit(1)
}

let svgURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let tileHex = args.count > 3 ? args[3] : "#EFCB68"

func color(_ hex: String) -> NSColor {
    var h = hex.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("#") { h.removeFirst() }
    var v: UInt64 = 0
    Scanner(string: h).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
guard let mark = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write("could not load \(svgURL.path)\n".data(using: .utf8)!)
    exit(2)
}

let tile = color(tileHex)
// Slightly lighter towards the top so the tile reads as a surface, like Apple's own icons.
let tileTop = tile.blended(withFraction: 0.04, of: .white) ?? tile
let tileBottom = tile.blended(withFraction: 0.03, of: .black) ?? tile

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.clear(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.imageInterpolation = .high

    // Apple's icon grid: the tile occupies 824/1024 of the canvas with a 185.4/1024 corner radius.
    let inset = s * (100.0 / 1024.0)
    let radius = s * (185.4 / 1024.0)
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(starting: tileBottom, ending: tileTop)!.draw(in: path, angle: 90)

    mark.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in entries {
    try! render(size: size).write(to: outDir.appendingPathComponent(name + ".png"))
}
print("rendered \(entries.count) images into \(outDir.path)")
