import AppKit

// Draw every icon size from the same vector geometry, without external assets.
func drawIcon(size: Int) -> Data? {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let background = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944),
                                  xRadius: 216, yRadius: 216)
    let navy = NSColor(calibratedRed: 0.065, green: 0.10, blue: 0.19, alpha: 1)
    let dusk = NSColor(calibratedRed: 0.16, green: 0.23, blue: 0.36, alpha: 1)
    NSGradient(starting: navy, ending: dusk)!.draw(in: background, angle: 55)

    let moon = NSBezierPath()
    moon.move(to: NSPoint(x: 642, y: 799))
    moon.curve(to: NSPoint(x: 642, y: 236),
               controlPoint1: NSPoint(x: 239, y: 850), controlPoint2: NSPoint(x: 218, y: 277))
    moon.curve(to: NSPoint(x: 642, y: 799),
               controlPoint1: NSPoint(x: 402, y: 366), controlPoint2: NSPoint(x: 398, y: 666))
    moon.close()
    let glow = NSShadow()
    glow.shadowColor = NSColor(calibratedRed: 0.62, green: 0.76, blue: 1, alpha: 0.17)
    glow.shadowBlurRadius = 38
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    NSColor(calibratedRed: 0.91, green: 0.94, blue: 1, alpha: 1).setFill()
    moon.fill()
    NSGraphicsContext.restoreGraphicsState()

    func star(x: CGFloat, y: CGFloat, radius: CGFloat) {
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: x, y: y + radius))
        shape.curve(to: NSPoint(x: x + radius, y: y),
                    controlPoint1: NSPoint(x: x + radius * 0.17, y: y + radius * 0.17),
                    controlPoint2: NSPoint(x: x + radius * 0.17, y: y + radius * 0.17))
        shape.curve(to: NSPoint(x: x, y: y - radius),
                    controlPoint1: NSPoint(x: x + radius * 0.17, y: y - radius * 0.17),
                    controlPoint2: NSPoint(x: x + radius * 0.17, y: y - radius * 0.17))
        shape.curve(to: NSPoint(x: x - radius, y: y),
                    controlPoint1: NSPoint(x: x - radius * 0.17, y: y - radius * 0.17),
                    controlPoint2: NSPoint(x: x - radius * 0.17, y: y - radius * 0.17))
        shape.curve(to: NSPoint(x: x, y: y + radius),
                    controlPoint1: NSPoint(x: x - radius * 0.17, y: y + radius * 0.17),
                    controlPoint2: NSPoint(x: x - radius * 0.17, y: y + radius * 0.17))
        shape.close()
        shape.fill()
    }
    NSColor(calibratedRed: 0.92, green: 0.78, blue: 0.53, alpha: 1).setFill()
    star(x: 734, y: 668, radius: 75)
    NSColor(calibratedRed: 0.65, green: 0.78, blue: 0.96, alpha: 0.85).setFill()
    star(x: 754, y: 419, radius: 26)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
    fputs("Usage: generate-icon OUTPUT.iconset [OUTPUT.icns]\n", stderr)
    exit(1)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let elementTypes = [16: ["icp4", "ic11"], 32: ["icp5", "ic12"], 128: ["ic07", "ic13"],
                    256: ["ic08", "ic14"], 512: ["ic09", "ic10"]]
var elements = Data()
func encodedLength(_ length: Int) -> Data {
    var value = UInt32(length).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(base)x\(base)\(suffix).png"
        guard let data = drawIcon(size: base * scale) else { fatalError("Could not encode icon") }
        try data.write(to: directory.appendingPathComponent(name))
        elements.append(contentsOf: elementTypes[base]![scale - 1].utf8)
        elements.append(encodedLength(data.count + 8))
        elements.append(data)
    }
}
if CommandLine.arguments.count == 3 {
    // Modern ICNS elements hold the same PNG images, with four-byte type tags
    // and big-endian element lengths. This also works when ImageIO's ICNS
    // encoder is unavailable in a restricted build environment.
    var family = Data("icns".utf8)
    family.append(encodedLength(elements.count + 8))
    family.append(elements)
    try family.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
