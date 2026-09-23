// Renders the README banner: the logo mark next to the word "Jayson" set in Raleway,
// on a flat tile-coloured background. Text is converted to outlines so the SVG needs
// no fonts installed wherever it is viewed (GitHub strips webfonts from SVG images).
//
// usage: swift Scripts/RenderBanner.swift <mark.svg> <out.svg> <out.png> [--fg HEX] [--bg HEX]
//        [--font PostScriptName] [--width N] [--height N]
import AppKit
import CoreText

var positional: [String] = []
var options: [String: String] = [:]
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a.hasPrefix("--"), let v = it.next() { options[a] = v } else { positional.append(a) }
}
guard positional.count == 3 else {
    FileHandle.standardError.write("usage: RenderBanner <mark.svg> <out.svg> <out.png> [--fg HEX] [--bg HEX] [--font NAME] [--width N] [--height N]\n".data(using: .utf8)!)
    exit(1)
}

let fg = options["--fg"] ?? "#562C2C"
let bg = options["--bg"] ?? "#EFCB68"
let fontName = options["--font"] ?? "RalewayRoman-SemiBold"
let width = Double(options["--width"] ?? "1600")!
let height = Double(options["--height"] ?? "400")!

// --- The mark -----------------------------------------------------------------------------------
// The recoloured mark (from recolor-logo.py, scale 1) lives on a 1024pt canvas; these are the
// bounds of the artwork itself, measured from Assets/logo.svg.
let markSVG = try! String(contentsOfFile: positional[0], encoding: .utf8)
let markPaths = markSVG.components(separatedBy: "<path ").dropFirst().map { "<path " + $0.components(separatedBy: "/>")[0] + "/>" }
let markBounds = CGRect(x: 316, y: 308.8, width: 392.3, height: 403)

let markHeight = height * 0.62
let markScale = markHeight / markBounds.height
let markWidth = markBounds.width * markScale

// --- The word -----------------------------------------------------------------------------------
let fontSize = CGFloat(height * 0.44)
guard let font = NSFont(name: fontName, size: fontSize) else {
    FileHandle.standardError.write("font \(fontName) is not installed\n".data(using: .utf8)!)
    exit(2)
}
let ctFont = font as CTFont
let word = "Jayson"
let attributed = NSAttributedString(string: word, attributes: [.font: font, .kern: fontSize * -0.01])
let line = CTLineCreateWithAttributedString(attributed)
var glyphPaths: [(CGPath, CGPoint)] = []
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
    CTRunGetPositions(run, CFRangeMake(0, count), &positions)
    let runFont = unsafeBitCast(CFDictionaryGetValue(CTRunGetAttributes(run), Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()), to: CTFont.self)
    for (g, p) in zip(glyphs, positions) {
        if let path = CTFontCreatePathForGlyph(runFont, g, nil) { glyphPaths.append((path, p)) }
    }
}
// Ink bounds of the word, so we can centre what is actually visible.
var inkBounds = CGRect.null
for (path, p) in glyphPaths {
    inkBounds = inkBounds.union(path.boundingBoxOfPath.offsetBy(dx: p.x, dy: p.y))
}
let capHeight = CTFontGetCapHeight(ctFont)

// --- Layout -------------------------------------------------------------------------------------
let gap = height * 0.11
let totalWidth = markWidth + gap + inkBounds.width
let left = (width - totalWidth) / 2
let centreY = height / 2
let markX = left - markBounds.minX * markScale
let markY = centreY - markHeight / 2 - markBounds.minY * markScale
let textX = left + markWidth + gap - inkBounds.minX
// SVG y grows downwards, glyph outlines grow upwards; centre the cap height on the mark.
let baselineY = centreY + capHeight / 2

// --- SVG ----------------------------------------------------------------------------------------
func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
func svgPath(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { el in
        let p = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: d += "M\(fmt(p[0].x)) \(fmt(p[0].y))"
        case .addLineToPoint: d += "L\(fmt(p[0].x)) \(fmt(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y))"
        case .addCurveToPoint: d += "C\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y)) \(fmt(p[2].x)) \(fmt(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

var svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="\(Int(width))" height="\(Int(height))" viewBox="0 0 \(Int(width)) \(Int(height))" role="img" aria-label="Jayson">
<rect width="\(Int(width))" height="\(Int(height))" fill="\(bg)"/>
<g transform="translate(\(fmt(markX)) \(fmt(markY))) scale(\(fmt(markScale)))">
\(markPaths.joined(separator: "\n"))
</g>
<g fill="\(fg)" transform="translate(\(fmt(textX)) \(fmt(baselineY))) scale(1 -1)">

"""
for (path, p) in glyphPaths {
    svg += "<path transform=\"translate(\(fmt(p.x)) \(fmt(p.y)))\" d=\"\(svgPath(path))\"/>\n"
}
svg += "</g>\n</svg>\n"
try! svg.write(toFile: positional[1], atomically: true, encoding: .utf8)

// --- PNG (2x) -----------------------------------------------------------------------------------
// Drawn from the same geometry rather than by rasterising the SVG, so the two always match.
func color(_ hex: String) -> NSColor {
    var h = hex; if h.hasPrefix("#") { h.removeFirst() }
    var v: UInt64 = 0; Scanner(string: h).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
let scale = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
cg.setAllowsAntialiasing(true)
cg.interpolationQuality = .high
// Flip so the coordinate system matches the SVG (origin top-left, y down).
cg.translateBy(x: 0, y: CGFloat(height)); cg.scaleBy(x: 1, y: -1)
cg.setFillColor(color(bg).cgColor)
cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
guard let mark = NSImage(contentsOfFile: positional[0]) else { exit(3) }
cg.saveGState()
cg.translateBy(x: markX, y: markY); cg.scaleBy(x: markScale, y: markScale)
cg.translateBy(x: 0, y: 1024); cg.scaleBy(x: 1, y: -1)   // NSImage draws y-up
mark.draw(in: CGRect(x: 0, y: 0, width: 1024, height: 1024), from: .zero, operation: .sourceOver, fraction: 1)
cg.restoreGState()
cg.saveGState()
cg.translateBy(x: textX, y: baselineY); cg.scaleBy(x: 1, y: -1)
cg.setFillColor(color(fg).cgColor)
for (path, p) in glyphPaths {
    cg.saveGState(); cg.translateBy(x: p.x, y: p.y); cg.addPath(path); cg.fillPath(); cg.restoreGState()
}
cg.restoreGState()
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: positional[2]))
print("wrote \(positional[1]) and \(positional[2]) (\(Int(width))x\(Int(height)), \(fontName))")
