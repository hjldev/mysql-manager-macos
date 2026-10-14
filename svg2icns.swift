// Render an SVG into an .icns file.
//   swift svg2icns.swift <in.svg> <out.icns>
//
// The system SVG renderer dithers gradients, and that noise makes PNGs
// several times larger. Each size is rendered at 8x and scaled down, which
// averages the noise away, then saved as PNG with zlib level 9. The .icns is
// written directly because iconutil re-encodes the PNGs with less compression.
import AppKit
import zlib

let args = CommandLine.arguments
guard args.count == 3, let svg = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write(Data("usage: swift svg2icns.swift <in.svg> <out.icns>\n".utf8))
    exit(1)
}

func bitmap(_ px: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)!
}

func draw(_ image: NSImage, into rep: NSBitmapImageRep) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ px: Int) -> NSBitmapImageRep {
    let big = bitmap(px * 8)
    draw(svg, into: big)
    let master = NSImage(size: NSSize(width: px, height: px))
    master.addRepresentation(big)
    let rep = bitmap(px)
    draw(master, into: rep)
    return rep
}

func bigEndian(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }

/// RGBA PNG, rows unfiltered (smallest for these images), zlib level 9.
func png(_ rep: NSBitmapImageRep) -> [UInt8] {
    let w = rep.pixelsWide, h = rep.pixelsHigh, p = rep.bitmapData!
    var raw = [UInt8]()
    raw.reserveCapacity((w * 4 + 1) * h)
    for y in 0..<h {
        raw.append(0) // filter: none
        for x in 0..<w {
            // the bitmap is premultiplied, PNG is not
            let o = y * rep.bytesPerRow + x * 4, a = Int(p[o + 3])
            for c in 0..<3 {
                raw.append(a == 0 || a == 255 ? p[o + c] : UInt8(min(255, (Int(p[o + c]) * 255 + a / 2) / a)))
            }
            raw.append(p[o + 3])
        }
    }
    var size = compressBound(uLong(raw.count))
    var z = [UInt8](repeating: 0, count: Int(size))
    guard compress2(&z, &size, raw, uLong(raw.count), 9) == Z_OK else { fatalError("zlib failed") }

    var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    func chunk(_ type: String, _ body: [UInt8]) {
        let t = Array(type.utf8)
        out += bigEndian(UInt32(body.count)) + t + body
        out += bigEndian(UInt32(crc32(crc32(0, t, uInt(t.count)), body, uInt(body.count))))
    }
    chunk("IHDR", bigEndian(UInt32(w)) + bigEndian(UInt32(h)) + [8, 6, 0, 0, 0]) // 8-bit RGBA
    chunk("sRGB", [0])
    chunk("IDAT", Array(z[..<Int(size)]))
    chunk("IEND", [])
    return out
}

// icns element types holding PNG data, by pixel size. No 16 and 32 pt @1x
// entries: Icon Services shows PNG data in those (icp4 / icp5, ic04 / ic05) as
// garbage, and scales the @2x ones down fine.
let types: [(String, Int)] = [
    ("ic11", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256), ("ic08", 256),
    ("ic14", 512), ("ic09", 512), ("ic10", 1024),
]
var pngs: [Int: [UInt8]] = [:]
var body = [UInt8]()
for (type, px) in types {
    if pngs[px] == nil { pngs[px] = png(render(px)) }
    body += Array(type.utf8) + bigEndian(UInt32(8 + pngs[px]!.count)) + pngs[px]!
}
let icns = Array("icns".utf8) + bigEndian(UInt32(8 + body.count)) + body
try Data(icns).write(to: URL(fileURLWithPath: args[2]))
