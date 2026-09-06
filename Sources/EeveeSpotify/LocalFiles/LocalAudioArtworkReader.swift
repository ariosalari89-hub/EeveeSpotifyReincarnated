import Foundation
import AVFoundation
import ImageIO

enum LocalAudioArtworkReader {
    // The owner calls this on its metadata queue, never from a player getter.
    // Synchronous AVFoundation access retains compatibility with iOS 14.
    static func artwork(in url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        let items = asset.commonMetadata.filter { $0.commonKey == .commonKeyArtwork }
        for item in items.prefix(16) {
            guard let data = item.dataValue, !data.isEmpty, data.count <= 8 * 1_024 * 1_024,
                  let source = CGImageSourceCreateWithData(data as CFData,
                      [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue <= 16_000, height.doubleValue <= 16_000,
                  width.doubleValue * height.doubleValue <= 40_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1_024,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { continue }
            // Native callers receive bounded, decoded image bytes even when
            // the original metadata omitted a MIME/dataType attribute.
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { return output as Data }
        }
        return nil
    }
}
