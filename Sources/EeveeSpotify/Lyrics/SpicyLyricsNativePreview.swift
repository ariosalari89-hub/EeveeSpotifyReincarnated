import Foundation

/// Spotify's server feed can omit Lyrics even when the chosen provider has it.
/// Restore only that native section: Spotify still creates/owns the card and
/// header, and the existing embedded renderer fills its ordinary content slot.
/// A nil result means the original response must be preserved byte-for-byte.
enum SpicyLyricsNativePreview {
    static func restoringMissingCard(in data: Data, for url: URL, enabled: Bool) -> Data? {
        let prefix = "/scrollsita/v1/scroll/spotify:track:"
        guard enabled, url.path.hasPrefix(prefix) else { return nil }
        let trackID = String(url.path.dropFirst(prefix.count))
        guard trackID.utf8.count == 22,
              trackID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              !data.isEmpty, data.count <= 4 * 1024 * 1024,
              let response = fields(in: data) else { return nil }
        // Wire schema verified in the supplied 9.1.76 executable's actual
        // SwiftProtobuf decoders. No Swift vtable/ivar offsets are invoked:
        // NpvScrollResponse.structure=1; NpvScrollStructure.sections=1;
        // Section.lyrics=5, section_info=23; Lyrics.entity_uri=1;
        // SectionInfo.section_id=1 (display_condition is left absent).
        let structures = response.filter { $0.number == 1 }
        guard structures.count == 1, let structure = structures.first, structure.wire == 2 else { return nil }
        let originalStructure = data.subdata(in: structure.value)
        guard let entries = fields(in: originalStructure) else { return nil }
        for entry in entries where entry.number == 1 {
            guard entry.wire == 2,
                  let section = fields(in: originalStructure.subdata(in: entry.value)) else { return nil }
            // Never duplicate or replace a server-owned Lyrics section, even
            // when its entity is relinked or its display policy differs.
            if section.contains(where: { $0.number == 5 }) { return nil }
        }
        let lyrics = messageField(1, Data(("spotify:track:" + trackID).utf8))
        let sectionInfo = messageField(1, Data(("eevee-spicy-lyrics:" + trackID).utf8))
        let newSection = messageField(5, lyrics) + messageField(23, sectionInfo)
        let restoredStructure = messageField(1, newSection) + originalStructure
        var result = data.subdata(in: 0..<structure.whole.lowerBound)
        result.append(messageField(1, restoredStructure))
        result.append(data.subdata(in: structure.whole.upperBound..<data.count))
        return result
    }

    private struct Field {
        let number: UInt64
        let wire: UInt64
        let whole: Range<Int>
        let value: Range<Int>
    }

    /// Preserve all unrecognized fields. Fail closed on malformed/group wire
    /// data instead of attempting to repair a feed whose shape is unknown.
    private static func fields(in data: Data) -> [Field]? {
        let bytes = Array(data)
        var cursor = 0
        var result = [Field]()
        while cursor < bytes.count {
            let start = cursor
            guard result.count < 4096, let key = readVarint(bytes, cursor: &cursor),
                  key >> 3 > 0, key >> 3 <= 0x1fffffff else { return nil }
            var valueStart = cursor
            switch key & 7 {
            case 0:
                guard readVarint(bytes, cursor: &cursor) != nil else { return nil }
            case 1:
                guard bytes.count - cursor >= 8 else { return nil }
                cursor += 8
            case 2:
                guard let length = readVarint(bytes, cursor: &cursor),
                      length <= UInt64(bytes.count - cursor) else { return nil }
                valueStart = cursor
                cursor += Int(length)
            case 5:
                guard bytes.count - cursor >= 4 else { return nil }
                cursor += 4
            default: return nil
            }
            result.append(Field(number: key >> 3, wire: key & 7,
                                whole: start..<cursor, value: valueStart..<cursor))
        }
        return result
    }

    private static func readVarint(_ bytes: [UInt8], cursor: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 70, by: 7) {
            guard cursor < bytes.count else { return nil }
            let byte = bytes[cursor]
            cursor += 1
            guard shift != 63 || byte <= 1 else { return nil }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }

    private static func messageField(_ number: UInt64, _ payload: Data) -> Data {
        var result = varint((number << 3) | 2)
        result.append(varint(UInt64(payload.count)))
        result.append(payload)
        return result
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes = [UInt8]()
        repeat {
            let low = UInt8(value & 0x7f)
            value >>= 7
            bytes.append(low | (value == 0 ? 0 : 0x80))
        } while value != 0
        return Data(bytes)
    }
}
