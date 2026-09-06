import Foundation

/// External Spotify feed contract, independently decoded for the UIKit fixture.
/// Verified against the supplied 9.1.76 binary, not the production patch encoder:
/// Response.structure=1; Structure.sections=1; Section.lyrics=5;
/// Lyrics.entity_uri=1. Explore and Credits are section cases 3 and 4.
enum NativeScrollFeedFixture {
    // Structure with Explore / Credits only, followed by response-info "test".
    static let withoutLyrics = Data([0x0a, 8, 0x0a, 2, 0x1a, 0, 0x0a, 2, 0x22, 0,
                                    0x12, 6, 0x0a, 4, 0x74, 0x65, 0x73, 0x74])
    struct Card { let kind: Int; let entityURI: String? }
    private enum InvalidFeed: Error { case truncated, unknownWire }

    static func cards(in response: Data) throws -> [Card] {
        guard let structure = try fields(response).first(where: { $0.0 == 1 })?.1 else { return [] }
        return try fields(structure).filter { $0.0 == 1 }.compactMap { _, section in
            let entries = try fields(section)
            guard let entry = entries.last(where: { [3, 4, 5].contains($0.0) }) else { return nil }
            let uriData = try fields(entry.1).first(where: { $0.0 == 1 })?.1
            return Card(kind: entry.0, entityURI: uriData.flatMap { String(data: $0, encoding: .utf8) })
        }
    }

    private static func fields(_ message: Data) throws -> [(Int, Data)] {
        let bytes = Array(message)
        var offset = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 70, by: 7) {
                guard offset < bytes.count else { throw InvalidFeed.truncated }
                let byte = bytes[offset]; offset += 1
                guard shift < 63 || byte <= 1 else { throw InvalidFeed.truncated }
                value |= UInt64(byte & 0x7f) << shift
                if byte < 128 { return value }
            }
            throw InvalidFeed.truncated
        }
        var result = [(Int, Data)]()
        while offset < bytes.count {
            let key = try varint()
            guard key >> 3 > 0 else { throw InvalidFeed.truncated }
            let size: Int
            switch key & 7 {
            case 0: _ = try varint(); continue
            case 1: size = 8
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count - offset) else { throw InvalidFeed.truncated }
                size = Int(length)
            case 5: size = 4
            default: throw InvalidFeed.unknownWire
            }
            guard size <= bytes.count - offset else { throw InvalidFeed.truncated }
            if key & 7 == 2 { result.append((Int(key >> 3), Data(bytes[offset..<(offset + size)]))) }
            offset += size
        }
        return result
    }
}
