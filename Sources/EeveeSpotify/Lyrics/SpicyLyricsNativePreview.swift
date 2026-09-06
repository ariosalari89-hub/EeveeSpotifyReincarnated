import Foundation

/// Native feed availability boundary. A nil result preserves the response.
enum SpicyLyricsNativePreview {
    static func restoringMissingCard(in data: Data, for url: URL, enabled: Bool) -> Data? {
        return nil
    }
}
