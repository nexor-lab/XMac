import AppKit

// Usage: make_icon <source.png> <iconset-dir>
// Takes a square source image and produces a macOS-style .iconset:
// the artwork is scaled into a centered rounded square with transparent
// padding, matching the macOS Big Sur icon grid.

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write("usage: make_icon <source.png> <iconset-dir>\n".data(using: .utf8)!)
    exit(1)
}
let sourcePath = CommandLine.arguments[1]
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = NSImage(contentsOfFile: sourcePath) else {
    FileHandle.standardError.write("cannot open \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

func render(px: Int) -> Data? {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let canvas = CGFloat(px)
    let shape = canvas * 0.8047
    let inset = (canvas - shape) / 2
    let radius = shape * 0.2249

    let clip = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: shape, height: shape),
        xRadius: radius, yRadius: radius)
    clip.addClip()
    source.draw(
        in: NSRect(x: inset, y: inset, width: shape, height: shape),
        from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for (name, px) in entries {
    guard let data = render(px: px) else {
        FileHandle.standardError.write("failed to render \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
