import Foundation
import ImageIO
import CoreGraphics

func runLocalAudioArtworkChecks() throws {
    let url = URL(fileURLWithPath: "Tests/LocalAudioImport/Fixtures/embedded-art.m4a")
    let before = try Data(contentsOf: url)
    guard let data = LocalAudioArtworkReader.artwork(in: url),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw TestFailure(description: "actual MP4 embedded cover art must become decodable image data")
    }
    var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
    let context = CGContext(data: &pixels, width: 32, height: 32, bitsPerComponent: 8,
                            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
    let after = try Data(contentsOf: url)
    try expect(image.width == 32 && image.height == 32 && pixels[0] > 200 && pixels[2] < 70 &&
               pixels[124] < 70 && pixels[126] > 200 && before == after,
               "the extracted cover must contain the embedded red/blue pixels and leave the audio file unchanged")
    print("PASS: real MP4 common artwork returns the actual embedded pixels without changing audio")
}
