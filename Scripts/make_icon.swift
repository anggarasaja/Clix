// Renders Clix.icns from an SF Symbol. Run via `swift Scripts/make_icon.swift <output.icns>`.
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Clix.icns"
let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Clix.iconset", isDirectory: true)

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func render(size: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let inset = size * 0.085
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: plate,
                                xRadius: plate.width * 0.225,
                                yRadius: plate.width * 0.225)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.44, green: 0.24, blue: 0.86, alpha: 1),
    ])
    gradient?.draw(in: squircle, angle: -90)

    let glyphSide = plate.width * 0.52
    let glyphRect = NSRect(x: plate.midX - glyphSide / 2,
                           y: plate.midY - glyphSide / 2,
                           width: glyphSide, height: glyphSide)
    let configuration = NSImage.SymbolConfiguration(pointSize: glyphSide, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let white = NSImage(size: glyphRect.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        white.draw(in: glyphRect)
    }

    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = render(size: variant.size) else {
        FileHandle.standardError.write(Data("Could not render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconsetURL.appendingPathComponent("\(variant.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
