// Generates every app icon asset from Design/AppIcon.png:
//   Sources/Toastune/Resources/AppIcon.icon  Icon Composer icon (macOS 26+), artwork filling the canvas
//   Sources/Toastune/Resources/AppIcon.icns  legacy icon, artwork on the 824/1024 macOS icon grid
//   Design/AppIcon-256.png                   README image
// Run from the repository root: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Sources/Toastune/Resources")
guard let source = NSImage(contentsOf: root.appendingPathComponent("Design/AppIcon.png")),
      let sourceImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Design/AppIcon.png is missing")
}

/// Bounds of the opaque artwork, in pixel coordinates with a bottom-left origin.
func opaqueBounds(_ image: CGImage) -> CGRect {
    let rep = NSBitmapImageRep(cgImage: image)
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return CGRect(x: minX, y: rep.pixelsHigh - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// Draws the artwork's opaque bounds into `target` on a transparent square canvas.
func render(pixels: Int, artworkIn target: CGRect) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let bounds = opaqueBounds(sourceImage)
    let scaleX = target.width / bounds.width, scaleY = target.height / bounds.height
    let drawn = CGRect(x: target.minX - bounds.minX * scaleX, y: target.minY - bounds.minY * scaleY,
                       width: CGFloat(sourceImage.width) * scaleX, height: CGFloat(sourceImage.height) * scaleY)
    context.cgContext.draw(sourceImage, in: drawn)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

// Icon Composer: the system masks the canvas to the app icon shape, so the artwork fills it.
let iconBundle = resources.appendingPathComponent("AppIcon.icon")
try? FileManager.default.removeItem(at: iconBundle)
try write(render(pixels: 1024, artworkIn: CGRect(x: 0, y: 0, width: 1024, height: 1024)),
          to: iconBundle.appendingPathComponent("Assets/artwork.png"))
let iconJSON = """
{
  "fill" : {
    "solid" : "extended-srgb:0.17000,0.17500,0.18500,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "artwork.png",
          "name" : "artwork"
        }
      ],
      "shadow" : {
        "kind" : "none",
        "opacity" : 0
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0
      }
    }
  ],
  "supported-platforms" : {
    "squares" : "shared"
  }
}
"""
try write(Data(iconJSON.utf8), to: iconBundle.appendingPathComponent("icon.json"))

// Legacy .icns: 824 pt body centred on the 1024 pt canvas.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let body = CGFloat(pixels) * 824 / 1024, inset = (CGFloat(pixels) - body) / 2
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try write(render(pixels: pixels, artworkIn: CGRect(x: inset, y: inset, width: body, height: body)),
                  to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()

let readmeBody = CGFloat(256) * 824 / 1024, readmeInset = (256 - readmeBody) / 2
try write(render(pixels: 256, artworkIn: CGRect(x: readmeInset, y: readmeInset, width: readmeBody, height: readmeBody)),
          to: root.appendingPathComponent("Design/AppIcon-256.png"))
print("Icon assets written")
