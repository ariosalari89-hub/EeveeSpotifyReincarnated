import Foundation

let trackID = "3N1zlgIGnFcnNiTuDaeYzy"
let musicURL = URL(string: "https://spclient.wg.spotify.com/scrollsita/v1/scroll/spotify:track:" + trackID)!
let original = NativeScrollFeedFixture.withoutLyrics
var checks = 0
func check(_ name: String, _ condition: Bool) {
    guard condition else { print("FAIL \(name)"); exit(1) }
    checks += 1
    print("PASS \(name)")
}
func patch(_ data: Data, _ url: URL = musicURL, enabled: Bool = true) -> Data? {
    SpicyLyricsNativePreview.restoringMissingCard(in: data, for: url, enabled: enabled)
}

let restored = patch(original) ?? original
let cards = try NativeScrollFeedFixture.cards(in: restored)
check("missing native preview is inserted before the unchanged Explore/Credits cards",
      cards.map(\.kind) == [5, 3, 4] && cards.first?.entityURI == "spotify:track:" + trackID)
check("existing section bytes and response-info bytes are retained exactly",
      restored.suffix(original.count - 2) == original.dropFirst(2))
check("restoration is idempotent", patch(restored) == nil)
check("disabled provider leaves a missing native card alone", patch(original, enabled: false) == nil)

// Independently encoded native Lyrics section, without our section metadata.
// Lengths are the literal wire contract: URI 36, Lyrics 38, Section 40, list 42.
let existing = Data([0x0a, 42, 0x0a, 40, 0x2a, 38, 0x0a, 36]) + Data(("spotify:track:" + trackID).utf8)
check("a server-owned Lyrics card is never replaced or duplicated", patch(existing) == nil)
let relinked = Data([0x0a, 42, 0x0a, 40, 0x2a, 38, 0x0a, 36]) + Data("spotify:track:1234567890123456789012".utf8)
check("a relinked server-owned Lyrics card is preserved", patch(relinked) == nil)
check("an existing empty Lyrics message is still Spotify-owned", patch(Data([0x0a, 4, 0x0a, 2, 0x2a, 0])) == nil)

for path in [
    "/scrollsita/v1/scroll/spotify:episode:" + trackID,
    "/scrollsita/v1/scroll/spotify:local:artist:album:track:123",
    "/scrollsita/v1/scroll/spotify:track:short",
    "/scrollsita/v1/scroll/spotify:track:123456789012345678901!",
    "/scrollsita/v1/scroll/spotify:track:" + trackID + "/extra",
    "/casita/v1/scroll/spotify:track:" + trackID,
    "/color-lyrics/v2/track/" + trackID
] {
    check("non-target request is unchanged: \(path)", patch(original, URL(string: "https://spclient.wg.spotify.com" + path)!) == nil)
}

// Unknown length-delimited, varint, fixed32 and fixed64 fields must survive.
let unknown = Data([0x9a, 6, 0xac, 2]) + Data(repeating: 0x7e, count: 300)
    + Data([0xa0, 6, 0x81, 1, 0xad, 6, 1, 2, 3, 4, 0xb1, 6, 1, 2, 3, 4, 5, 6, 7, 8])
let withUnknown = original + unknown
let preserved = patch(withUnknown) ?? withUnknown
check("unknown root fields of every supported wire type survive byte-for-byte",
      preserved.suffix(original.count - 2 + unknown.count) == withUnknown.dropFirst(2))
let unknownStructure = Data([0x0a, 12, 0x9a, 6, 1, 0x61]) + original.subdata(in: 2..<10) + original.suffix(8)
check("unknown structure fields survive alongside the new native section",
      (patch(unknownStructure) ?? Data()).suffix(unknownStructure.count - 2) == unknownStructure.dropFirst(2))
let empty = patch(Data([0x0a, 0])) ?? Data()
check("a valid empty music feed can create its first native card",
      try NativeScrollFeedFixture.cards(in: empty).map(\.kind) == [5])

let malformed: [[UInt8]] = [
    [], [0], [0x0a], [0x0a, 4, 0x0a, 9], [0x0a, 0, 0x0a, 0],
    [8, 1], [0x0a, 2, 8, 1], [0x0a, 4, 0x0a, 2, 0x2b, 0x2c],
    [0x0a, 0, 0x9d, 6, 1], [0x0a, 0, 0x99, 6, 1],
    [0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 1],
    [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2]
]
for (index, bytes) in malformed.enumerated() {
    check("malformed or ambiguous feed \(index) is untouched", patch(Data(bytes)) == nil)
}
check("oversized feeds are untouched", patch(Data(repeating: 0, count: 4 * 1024 * 1024 + 1)) == nil)
print("PASS all \(checks) native preview feed checks")
