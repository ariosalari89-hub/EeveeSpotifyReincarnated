import AppKit
import Foundation

// Inspect the real simulator display, not a UIKit hierarchy/WK-only snapshot.
// The availability fixture has a black background and white/gray lyric glyphs.
// Both native slots must actually paint before the fixture is allowed to detach.
guard CommandLine.arguments.count == 2,
      let image = NSBitmapImageRep(contentsOfFile: CommandLine.arguments[1]),
      image.pixelsWide > 0, image.pixelsHigh > image.pixelsWide else {
    fputs("Availability capture is missing or not portrait\n", stderr)
    exit(1)
}

let scaleX = Double(image.pixelsWide) / 393.0
let scaleY = Double(image.pixelsHigh) / 852.0
func paintedPixels(x: Double, y: Double, width: Double, height: Double) -> Int {
    let left = max(0, Int(x * scaleX))
    let top = max(0, Int(y * scaleY))
    let right = min(image.pixelsWide, Int((x + width) * scaleX))
    let bottom = min(image.pixelsHigh, Int((y + height) * scaleY))
    var count = 0
    for row in top..<bottom {
        for column in left..<right {
            guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { continue }
            if min(color.redComponent, min(color.greenComponent, color.blueComponent)) > 0.16,
               color.alphaComponent > 0.8 {
                count += 1
            }
        }
    }
    return count
}

let caption = paintedPixels(x: 24, y: 140, width: 320, height: 52)
let card = paintedPixels(x: 16, y: 200, width: 340, height: 320)
print("availability display glyph pixels: caption=\(caption), card=\(card)")
guard caption > 100, card > 100 else { exit(1) }
