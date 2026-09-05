import Foundation
import ObjectiveC.runtime

/// Spotify's has_lyrics flag describes its own catalogue, not the selected
/// third-party provider. Allow a provider lookup for music tracks, without
/// mutating the stored track, changing URIs or enabling obsolete 9.1 hooks.
enum SpicyLyricsAvailability {
    private static var installed = false
    private static var enabled: () -> Bool = { false }

    static func install(isEnabled: @escaping () -> Bool) {
        enabled = isEnabled
        guard !installed else { return }
        // Verified in the supplied Spotify 9.1.76 ARM64 executable:
        // SPTPlayerTrack metadata and URI both use the @16@0:8 getter ABI.
        guard let cls = NSClassFromString("SPTPlayerTrack") else { return }
        let metadataSelector = NSSelectorFromString("metadata")
        let uriSelector = NSSelectorFromString("URI")
        guard let metadata = objectGetter(cls, metadataSelector),
              let uri = objectGetter(cls, uriSelector) else { return }
        typealias Getter = @convention(c) (NSObject, Selector) -> Unmanaged<AnyObject>?
        let original = unsafeBitCast(method_getImplementation(metadata), to: Getter.self)
        let originalURI = unsafeBitCast(method_getImplementation(uri), to: Getter.self)
        let block: @convention(block) (NSObject) -> AnyObject? = { track in
            let value = original(track, metadataSelector)?.takeUnretainedValue()
            guard enabled(), let dictionary = value as? NSDictionary,
                  let url = originalURI(track, uriSelector)?.takeUnretainedValue() as? NSURL,
                  let identifier = url.absoluteString,
                  identifier.hasPrefix("spotify:track:") else { return value }
            let trackID = identifier.dropFirst("spotify:track:".count)
            guard trackID.utf8.count == 22,
                  trackID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
                  dictionary["has_lyrics"] as? String != "true",
                  let copy = dictionary.mutableCopy() as? NSMutableDictionary else { return value }
            copy["has_lyrics"] = "true"
            return copy.copy() as AnyObject
        }
        let replacement = imp_implementationWithBlock(block)
        // Never replace an inherited superclass getter globally.
        if !class_addMethod(cls, metadataSelector, replacement, method_getTypeEncoding(metadata)) {
            method_setImplementation(metadata, replacement)
        }
        installed = true
        writeDebugLog("[SpicyLyrics] installed guarded music-track lyrics availability")
    }

    private static func objectGetter(_ cls: AnyClass, _ selector: Selector) -> Method? {
        guard let method = class_getInstanceMethod(cls, selector), method_getNumberOfArguments(method) == 2 else { return nil }
        let result = method_copyReturnType(method)
        defer { free(result) }
        return result.pointee == 64 ? method : nil
    }
}
