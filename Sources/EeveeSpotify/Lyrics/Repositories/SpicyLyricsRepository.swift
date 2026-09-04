import Foundation

private enum SpicyLyricsServiceError: Error {
    case authenticationUnavailable
    case cancelled
    case queued
    case rateLimited
    case transportStatus(Int, TimeInterval?)
}

private enum SpicyLyricsPayloadFidelity: Int, Codable {
    case unavailable = 0
    case staticLyrics = 1
    case line = 2
    case syllable = 3

    init(type: String) {
        switch type.lowercased() {
        case "syllable": self = .syllable
        case "line": self = .line
        case "static": self = .staticLyrics
        default: self = .unavailable
        }
    }
}

private struct SpicyLyricsRendererCacheEnvelope: Codable {
    let schemaVersion: Int
    let storedAt: TimeInterval
    let status: Int
    let payload: Data?
    let lyricsType: String?
    let entryCount: Int?
}

private struct SpicyLyricsResolvedPayload {
    let rendererData: Data
    let dto: LyricsDto
    let type: String
    let fidelity: SpicyLyricsPayloadFidelity
    let entryCount: Int
}

private final class SpicyLyricsInFlightRequest {
    let completion = DispatchGroup()
    var payload: SpicyLyricsResolvedPayload?
    var error: Error?

    init() {
        completion.enter()
    }
}

// MARK: - SpicyLyricsRepository
//
// Fetches lyrics from api.spicylyrics.org and converts the response into LyricsDto.
//
// ── Token availability ───────────────────────────────────────────────────────
// spotifyAccessToken is captured lazily from Spotify's outgoing requests.
// On first track load it may be nil. The Spicetify extension uses
// Platform.GetSpotifyAccessToken() which awaits the token asynchronously.
// We replicate that by polling spotifyAccessToken for up to 5 seconds before
// giving up — this prevents an immediate 401 from the API triggering Genius fallback.
//
// ── iOS 27 crash ─────────────────────────────────────────────────────────────
// The EXC_BREAKPOINT / _swift_task_checkIsolatedSwift crash is fixed in
// DataLoaderServiceHooks.x.swift by dispatching orig.URLSession callbacks
// onto the main queue. No changes needed here for that.

class SpicyLyricsRepository: LyricsRepository {

    static let shared = SpicyLyricsRepository()
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 15
        config.allowsExpensiveNetworkAccess   = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)

        if let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let directory = base
                .appendingPathComponent("EeveeSpotify", isDirectory: true)
                .appendingPathComponent("SpicyLyrics", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                self.rendererCacheDirectory = directory
            } catch {
                self.rendererCacheDirectory = nil
                writeDebugLog("[SpicyLyrics] Could not create persistent cache: \(error)")
            }
        } else {
            self.rendererCacheDirectory = nil
        }

        pruneExpiredRendererCache()
    }

    private let session: URLSession
    private let rendererCacheDirectory: URL?
    private let rendererCacheLock = NSLock()
    private var rendererPayloadCache: [String: SpicyLyricsRendererCacheEnvelope] = [:]
    private let inFlightLock = NSLock()
    private var inFlightRequests: [String: SpicyLyricsInFlightRequest] = [:]

    private static let apiUrl        = "https://api.spicylyrics.org"
    private static let authHeaderKey = "SpicyLyrics-WebAuth"
    // Keep this aligned with the current public Spicy Lyrics client. The API
    // replaces real lyrics with an update notice when this value is too old.
    private static let clientVersion = "6.3.12"
    private static let rendererCacheSchemaVersion = 2
    private static let rendererCacheLifetime: TimeInterval = 3 * 24 * 60 * 60
    // Static is a valid final result for some songs, but the service can also
    // briefly return it while a timed AML payload is becoming available. Keep
    // it only long enough to prevent an immediate duplicate attachment from
    // repeating the bounded upgrade probes.
    private static let staticRendererCacheLifetime: TimeInterval = 30
    private static let maximumMemoryCacheEntries = 32

    // MARK: - Lossless payload cache

    private func rendererCacheURL(for trackId: String) -> URL? {
        guard let rendererCacheDirectory,
              let safeName = trackId.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              !safeName.isEmpty else { return nil }
        return rendererCacheDirectory.appendingPathComponent("\(safeName).json", isDirectory: false)
    }

    private func isCurrent(_ envelope: SpicyLyricsRendererCacheEnvelope, now: TimeInterval) -> Bool {
        let lifetime = envelope.lyricsType.map {
            SpicyLyricsPayloadFidelity(type: $0) == .staticLyrics
                ? Self.staticRendererCacheLifetime
                : Self.rendererCacheLifetime
        } ?? Self.rendererCacheLifetime
        return envelope.schemaVersion == Self.rendererCacheSchemaVersion
            && envelope.storedAt <= now
            && now - envelope.storedAt < lifetime
            && (envelope.status == 404 || (envelope.status == 200 && envelope.payload != nil))
    }

    private func cachedRendererPayload(for trackId: String) throws -> Data? {
        let now = Date().timeIntervalSince1970
        rendererCacheLock.lock()
        defer { rendererCacheLock.unlock() }

        var envelope = rendererPayloadCache[trackId]
        if envelope == nil,
           let url = rendererCacheURL(for: trackId),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(SpicyLyricsRendererCacheEnvelope.self, from: data) {
            envelope = decoded
        }

        guard let envelope else { return nil }
        guard isCurrent(envelope, now: now) else {
            rendererPayloadCache.removeValue(forKey: trackId)
            if let url = rendererCacheURL(for: trackId) {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }

        rendererPayloadCache[trackId] = envelope
        if envelope.status == 404 { throw LyricsError.noSuchSong }
        return envelope.payload
    }

    private func storeRendererCache(
        status: Int,
        payload: Data?,
        lyricsType: String? = nil,
        entryCount: Int? = nil,
        for trackId: String
    ) -> Data? {
        let incoming = SpicyLyricsRendererCacheEnvelope(
            schemaVersion: Self.rendererCacheSchemaVersion,
            storedAt: Date().timeIntervalSince1970,
            status: status,
            payload: payload,
            lyricsType: lyricsType,
            entryCount: entryCount
        )

        rendererCacheLock.lock()
        var existing = rendererPayloadCache[trackId]
        if existing == nil,
           let url = rendererCacheURL(for: trackId),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(SpicyLyricsRendererCacheEnvelope.self, from: data),
           isCurrent(decoded, now: Date().timeIntervalSince1970) {
            existing = decoded
        }

        let envelope: SpicyLyricsRendererCacheEnvelope
        if let existing,
           existing.status == 200,
           (incoming.status == 404
            || (incoming.status == 200 && isHigherQuality(existing, than: incoming))) {
            envelope = existing
            writeDebugLog(
                "[SpicyLyrics] Kept higher-quality \(existing.lyricsType ?? "unknown") cache "
                + "instead of status=\(incoming.status) "
                + "type=\(incoming.lyricsType ?? "unknown") for \(trackId)"
            )
        } else {
            envelope = incoming
        }

        rendererPayloadCache[trackId] = envelope
        if rendererPayloadCache.count > Self.maximumMemoryCacheEntries,
           let oldest = rendererPayloadCache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            rendererPayloadCache.removeValue(forKey: oldest)
        }
        if let url = rendererCacheURL(for: trackId),
           let encoded = try? JSONEncoder().encode(envelope) {
            do {
                try encoded.write(to: url, options: .atomic)
            } catch {
                writeDebugLog("[SpicyLyrics] Could not persist cache for \(trackId): \(error)")
            }
        }
        rendererCacheLock.unlock()
        return envelope.payload
    }

    private func isHigherQuality(
        _ lhs: SpicyLyricsRendererCacheEnvelope,
        than rhs: SpicyLyricsRendererCacheEnvelope
    ) -> Bool {
        let lhsFidelity = SpicyLyricsPayloadFidelity(type: lhs.lyricsType ?? "")
        let rhsFidelity = SpicyLyricsPayloadFidelity(type: rhs.lyricsType ?? "")
        if lhsFidelity != rhsFidelity { return lhsFidelity.rawValue > rhsFidelity.rawValue }
        let lhsEntries = lhs.entryCount ?? 0
        let rhsEntries = rhs.entryCount ?? 0
        if lhsEntries != rhsEntries { return lhsEntries > rhsEntries }
        return (lhs.payload?.count ?? 0) > (rhs.payload?.count ?? 0)
    }

    @discardableResult
    private func cacheRendererPayload(
        _ payload: SpicyLyricsResolvedPayload,
        for trackId: String
    ) -> Data? {
        storeRendererCache(
            status: 200,
            payload: payload.rendererData,
            lyricsType: payload.type,
            entryCount: payload.entryCount,
            for: trackId
        )
    }

    private func cacheMissingLyrics(for trackId: String) {
        storeRendererCache(status: 404, payload: nil, for: trackId)
    }

    private func removeRendererCache(for trackId: String) {
        rendererCacheLock.lock()
        rendererPayloadCache.removeValue(forKey: trackId)
        if let url = rendererCacheURL(for: trackId) {
            try? FileManager.default.removeItem(at: url)
        }
        rendererCacheLock.unlock()
    }

    private func pruneExpiredRendererCache() {
        guard let rendererCacheDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: rendererCacheDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return }
        let now = Date().timeIntervalSince1970
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let envelope = try? JSONDecoder().decode(
                    SpicyLyricsRendererCacheEnvelope.self,
                    from: data
                  ),
                  isCurrent(envelope, now: now) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
        }
    }

    // MARK: - Token wait
    //
    // Poll for spotifyAccessToken up to `timeout` seconds.
    // Returns the token or nil if not available in time.
    private func waitForToken(timeout: TimeInterval = 8.0) -> String? {
        if let token = spotifyAccessToken { return token }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            if let token = spotifyAccessToken { return token }
        }
        return nil
    }

    // MARK: - Network

    private func performNetworkQuery(trackId: String) throws -> Data {
        guard let url = URL(string: "\(SpicyLyricsRepository.apiUrl)/query") else {
            throw LyricsError.decodingError
        }

        let body: [String: Any] = [
            "queries": [
                [
                    "operation": "lyrics",
                    "variables": [
                        "id":   trackId,
                        "auth": SpicyLyricsRepository.authHeaderKey
                    ]
                ]
            ],
            "client": ["version": SpicyLyricsRepository.clientVersion]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json",                   forHTTPHeaderField: "Content-Type")
        request.setValue(SpicyLyricsRepository.clientVersion, forHTTPHeaderField: "SpicyLyrics-Version")
        request.setValue("2",                                forHTTPHeaderField: "X-mode")

        // A browser supplies these identity headers around desktop Spicy
        // Lyrics' explicit Content-Type/version/X-mode/auth headers. Preserve
        // that request shape, but let URLSession negotiate compression itself;
        // advertising an unsupported codec can turn a valid JSON response into
        // undecodable bytes on older iOS versions.
        request.setValue("https://xpui.app.spotify.com",  forHTTPHeaderField: "Origin")
        request.setValue("https://xpui.app.spotify.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.7680.179 Spotify/1.2.92.148 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("\"Windows\"",                      forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("\"Not-A.Brand\";v=\"24\", \"Chromium\";v=\"146\"", forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?0",                                forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("*/*",                               forHTTPHeaderField: "Accept")
        request.setValue("cross-site",                        forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors",                              forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty",                             forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("en-Latn-US,en-US;q=0.9,en-Latn;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")

        // Wait for the Spotify Bearer token — mirrors Platform.GetSpotifyAccessToken()
        // in the Spicetify extension. Without a valid token the API returns non-200
        // immediately, which falsely triggers Genius fallback.
        guard let token = waitForToken() else {
            writeDebugLog("[SpicyLyrics] No Spotify token available for \(trackId)")
            throw SpicyLyricsServiceError.authenticationUnavailable
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: SpicyLyricsRepository.authHeaderKey)
        writeDebugLog("[SpicyLyrics] Using captured token for \(trackId)")

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var urlResponse: HTTPURLResponse?

        session.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            urlResponse = response as? HTTPURLResponse
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let error = responseError {
            writeDebugLog("[SpicyLyrics] Network error for \(trackId): \(error)")
            throw error
        }
        guard let data = responseData else {
            writeDebugLog("[SpicyLyrics] No data for \(trackId)")
            throw LyricsError.decodingError
        }
        let statusCode = urlResponse?.statusCode ?? 0
        let retryAfter = Self.retryAfter(from: urlResponse?.value(forHTTPHeaderField: "Retry-After"))
        writeDebugLog("[SpicyLyrics] Transport status \(statusCode), \(data.count) bytes for \(trackId)")
        guard (200 ..< 300).contains(statusCode) else {
            if statusCode == 401 || statusCode == 403 {
                spotifyAccessToken = nil
                throw SpicyLyricsServiceError.authenticationUnavailable
            }
            if statusCode == 429 { throw SpicyLyricsServiceError.rateLimited }
            throw SpicyLyricsServiceError.transportStatus(statusCode, retryAfter)
        }
        return data
    }

    private static func retryAfter(from header: String?) -> TimeInterval? {
        guard let header, !header.isEmpty else { return nil }
        if let seconds = Double(header), seconds > 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: header) else { return nil }
        let interval = date.timeIntervalSinceNow
        return interval > 0 ? interval : nil
    }

    // MARK: - Parse

    private func decodeNetworkResponse(
        _ data: Data,
        trackId: String
    ) throws -> SpicyLyricsResolvedPayload {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let queriesRaw = json["queries"] as? [[String: Any]]
        else {
            let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[SpicyLyrics] Malformed envelope for \(trackId): \(rawBody)")
            throw LyricsError.decodingError
        }

        // The server may prepend extra entries ahead of the real query result
        // (e.g. a "_notice" block with no "operationId"/"result"). The real
        // Spicetify client never assumes index 0 — it looks results up by
        // operationId via queries.get("0") — so we match that instead of
        // blindly taking queriesRaw.first.
        guard
            let matchedQuery = queriesRaw.first(where: { $0["operationId"] as? String == "0" }),
            let result = matchedQuery["result"] as? [String: Any]
        else {
            let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[SpicyLyrics] No matching operationId 0 for \(trackId): \(rawBody)")
            throw LyricsError.decodingError
        }

        let httpStatus = result["httpStatus"] as? Int ?? 0
        writeDebugLog("[SpicyLyrics] API status \(httpStatus) for \(trackId)")

        switch httpStatus {
        case 404:
            throw LyricsError.noSuchSong
        case 200:
            break
        case 503:
            throw SpicyLyricsServiceError.queued
        case 429:
            throw SpicyLyricsServiceError.rateLimited
        case 401, 403:
            // Auth failure — token was stale or rejected. Clear it so the next
            // attempt re-waits for a fresh one.
            writeDebugLog("[SpicyLyrics] Auth error \(httpStatus) for \(trackId) — clearing cached token")
            spotifyAccessToken = nil
            throw SpicyLyricsServiceError.authenticationUnavailable
        default:
            writeDebugLog("[SpicyLyrics] Unexpected status \(httpStatus) for \(trackId)")
            throw SpicyLyricsServiceError.transportStatus(httpStatus, nil)
        }

        guard let rawData = result["data"] else { throw LyricsError.decodingError }

        let packed: SLObjPackValue
        do {
            packed = try SLObjPack.unpack(rawData)
        } catch {
            writeDebugLog("[SpicyLyrics] SLObjPack error for \(trackId): \(error)")
            throw LyricsError.decodingError
        }

        let rendererData: Data
        do {
            rendererData = try packed.jsonData()
        } catch {
            writeDebugLog("[SpicyLyrics] Could not serialize renderer payload for \(trackId): \(error)")
            throw LyricsError.decodingError
        }

        return try makeResolvedPayload(
            packed,
            rendererData: rendererData,
            trackId: trackId,
            origin: "network"
        )
    }

    private func decodeRendererPayload(
        _ data: Data,
        trackId: String
    ) throws -> SpicyLyricsResolvedPayload {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            writeDebugLog("[SpicyLyrics] Invalid cached renderer JSON for \(trackId): \(error)")
            throw LyricsError.decodingError
        }

        let packed = try rendererValue(from: raw, depth: 0)
        return try makeResolvedPayload(
            packed,
            rendererData: data,
            trackId: trackId,
            origin: "cache"
        )
    }

    private func makeResolvedPayload(
        _ packed: SLObjPackValue,
        rendererData: Data,
        trackId: String,
        origin: String
    ) throws -> SpicyLyricsResolvedPayload {
        guard let type = packed["Type"]?.stringValue else {
            writeDebugLog("[SpicyLyrics] Missing Type in \(origin) payload for \(trackId)")
            throw LyricsError.decodingError
        }

        let contentCount = packed["Content"]?.arrayValue?.count
            ?? packed["Lines"]?.arrayValue?.count
            ?? 0
        let source = packed["source"]?.stringValue ?? "unknown"
        writeDebugLog(
            "[SpicyLyrics] Lyrics type=\(type), source=\(source), entries=\(contentCount), "
            + "origin=\(origin) for \(trackId)"
        )

        let dto: LyricsDto
        switch type {
        case "Syllable": dto = parseSyllableLyrics(packed)
        case "Line": dto = parseLineLyrics(packed)
        case "Static": dto = parseStaticLyrics(packed)
        default:
            writeDebugLog("[SpicyLyrics] Unknown type '\(type)' for \(trackId)")
            throw LyricsError.decodingError
        }

        return SpicyLyricsResolvedPayload(
            rendererData: rendererData,
            dto: dto,
            type: type,
            fidelity: SpicyLyricsPayloadFidelity(type: type),
            entryCount: contentCount
        )
    }

    private func rendererValue(from raw: Any, depth: Int) throws -> SLObjPackValue {
        guard depth <= 128 else { throw LyricsError.decodingError }
        switch raw {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            let number = value.doubleValue
            guard number.isFinite else { throw LyricsError.decodingError }
            return .number(number)
        case let value as String:
            return .string(value)
        case let values as [Any]:
            guard values.count <= 100_000 else { throw LyricsError.decodingError }
            return .array(try values.map { try rendererValue(from: $0, depth: depth + 1) })
        case let values as [String: Any]:
            guard values.count <= 10_000 else { throw LyricsError.decodingError }
            var result = [String: SLObjPackValue]()
            result.reserveCapacity(values.count)
            for (key, value) in values {
                result[key] = try rendererValue(from: value, depth: depth + 1)
            }
            return .object(result)
        default:
            throw LyricsError.decodingError
        }
    }

    // MARK: Syllable lyrics

    private func parseSyllableLyrics(_ root: SLObjPackValue) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        var hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal",
                  let lead = entry["Lead"] else { continue }

            let lineText: String
            if let syllables = lead["Syllables"]?.arrayValue, !syllables.isEmpty {
                // Real client rule (Syllable.ts): IsPartOfWord marks a syllable
                // that joins the *next* syllable. The old parser read the flag in
                // the opposite direction, producing "A ny" and "fanta sy" on a
                // broad class of otherwise-valid karaoke payloads.
                var text = ""
                for (index, syllable) in syllables.enumerated() {
                    guard let syllableText = syllable["Text"]?.stringValue else { continue }
                    let previousJoinsCurrent = index > 0
                        && (syllables[index - 1]["IsPartOfWord"]?.boolValue ?? false)
                    let startsWithPunctuation = syllableText.first.map {
                        ",.;:!?%)]}\u{2019}\u{201D}".contains($0)
                    } ?? false
                    if !text.isEmpty && !previousJoinsCurrent && !startsWithPunctuation {
                        text += " "
                    }
                    text += syllableText
                }
                lineText = text
                if syllables.contains(where: { ($0["TransliteratedText"]?.stringValue ?? "").isEmpty == false }) {
                    hasRomanized = true
                }
            } else if let text = lead["Text"]?.stringValue {
                lineText = text
            } else {
                continue
            }

            if (lead["TransliteratedText"]?.stringValue ?? "").isEmpty == false { hasRomanized = true }

            let offsetMs = lead["StartTime"]?.doubleValue.map { Int($0 * 1000) }
            lines.append(LyricsLineDto(content: lineText.lyricsNoteIfEmpty, offsetMs: offsetMs))
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization)
    }

    // MARK: Line lyrics

    private func parseLineLyrics(_ root: SLObjPackValue) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        let hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal" else { continue }
            let text      = entry["Lead"]?["Text"]?.stringValue ?? entry["Text"]?.stringValue ?? ""
            let startTime = entry["Lead"]?["StartTime"]?.doubleValue ?? entry["StartTime"]?.doubleValue
            lines.append(LyricsLineDto(content: text.lyricsNoteIfEmpty, offsetMs: startTime.map { Int($0 * 1000) }))
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization)
    }

    // MARK: Static lyrics

    private func parseStaticLyrics(_ root: SLObjPackValue) -> LyricsDto {
        let rawLines = root["Lines"]?.arrayValue ?? []
        let lines = rawLines.compactMap { entry -> LyricsLineDto? in
            guard let text = entry["Text"]?.stringValue else { return nil }
            return LyricsLineDto(content: text.lyricsNoteIfEmpty, offsetMs: nil)
        }
        let romanization: LyricsRomanizationStatus = lines.map(\.content).canBeRomanized
            ? .canBeRomanized : .original
        return LyricsDto(lines: lines, timeSynced: false, romanization: romanization)
    }

    private func emptyDto() -> LyricsDto {
        LyricsDto(lines: [], timeSynced: false, romanization: .original)
    }

    // MARK: - LyricsRepository

    private func resolvedPayload(
        for trackId: String,
        forceRefresh: Bool,
        shouldContinue: () -> Bool
    ) throws -> SpicyLyricsResolvedPayload {
        var preservedPayload: SpicyLyricsResolvedPayload?
        if forceRefresh {
            // A manual retry asks the network for a better answer; it does not
            // authorize a transient 404/Static response to destroy a working
            // Line/Syllable payload. Keep the last decodable response until a
            // successful fetch has passed the same fidelity comparator.
            if let cached = try? cachedRendererPayload(for: trackId) {
                preservedPayload = try? decodeRendererPayload(cached, trackId: trackId)
            }
        } else if let cached = try cachedRendererPayload(for: trackId) {
            do {
                let payload = try decodeRendererPayload(cached, trackId: trackId)
                writeDebugLog(
                    "[SpicyLyrics] Lossless \(payload.type) cache hit for \(trackId)"
                )
                return payload
            } catch {
                writeDebugLog("[SpicyLyrics] Discarding unreadable cache for \(trackId)")
                removeRendererCache(for: trackId)
            }
        }

        let request: SpicyLyricsInFlightRequest
        let isLeader: Bool
        inFlightLock.lock()
        if let current = inFlightRequests[trackId] {
            request = current
            isLeader = false
        } else {
            request = SpicyLyricsInFlightRequest()
            inFlightRequests[trackId] = request
            isLeader = true
        }
        inFlightLock.unlock()

        if !isLeader {
            writeDebugLog("[SpicyLyrics] Joined in-flight request for \(trackId)")
            while request.completion.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                guard shouldContinue() else { throw SpicyLyricsServiceError.cancelled }
            }
            inFlightLock.lock()
            let payload = request.payload
            let error = request.error
            inFlightLock.unlock()
            if let payload { return payload }
            throw error ?? LyricsError.unknownError
        }

        do {
            let fetched = try fetchBestRemotePayload(
                trackId: trackId,
                shouldContinue: shouldContinue
            )
            var selected = fetched
            if let selectedData = cacheRendererPayload(fetched, for: trackId),
               selectedData != fetched.rendererData {
                do {
                    selected = try decodeRendererPayload(selectedData, trackId: trackId)
                } catch {
                    removeRendererCache(for: trackId)
                    _ = cacheRendererPayload(fetched, for: trackId)
                    selected = fetched
                }
            }
            finishInFlight(request, trackId: trackId, payload: selected, error: nil)
            return selected
        } catch {
            if let preservedPayload {
                writeDebugLog(
                    "[SpicyLyrics] Refresh failed; retained \(preservedPayload.type) for \(trackId)"
                )
                finishInFlight(
                    request,
                    trackId: trackId,
                    payload: preservedPayload,
                    error: nil
                )
                return preservedPayload
            }
            if let lyricsError = error as? LyricsError,
               case .noSuchSong = lyricsError {
                cacheMissingLyrics(for: trackId)
            }
            finishInFlight(request, trackId: trackId, payload: nil, error: error)
            throw error
        }
    }

    private func finishInFlight(
        _ request: SpicyLyricsInFlightRequest,
        trackId: String,
        payload: SpicyLyricsResolvedPayload?,
        error: Error?
    ) {
        inFlightLock.lock()
        request.payload = payload
        request.error = error
        if let current = inFlightRequests[trackId], current === request {
            inFlightRequests.removeValue(forKey: trackId)
        }
        inFlightLock.unlock()
        request.completion.leave()
    }

    private func fetchBestRemotePayload(
        trackId: String,
        shouldContinue: () -> Bool
    ) throws -> SpicyLyricsResolvedPayload {
        var best = try fetchRemotePayload(
            trackId: trackId,
            shouldContinue: shouldContinue
        )

        // The service can return Static, Line and Syllable payloads for the
        // same track in adjacent requests. That race was visible in the device
        // log: the lower-fidelity response sometimes landed last and made a
        // timed song look completely inert. Probe every non-syllable result on
        // a short bounded schedule, then retain the best response. This also
        // lets a transient Line result upgrade to the word-timed payload used
        // by desktop Spicy Lyrics.
        guard best.fidelity != .syllable else { return best }
        let upgradeDelays: [TimeInterval] = [0.16, 0.38, 0.72]
        for (offset, delay) in upgradeDelays.enumerated() {
            let attempt = offset + 1
            try waitForRetry(delay, shouldContinue: shouldContinue)
            do {
                let candidate = try fetchRemotePayload(
                    trackId: trackId,
                    shouldContinue: shouldContinue
                )
                if isHigherQuality(candidate, than: best) {
                    writeDebugLog(
                        "[SpicyLyrics] Upgraded \(trackId) from \(best.type) to \(candidate.type) "
                        + "on probe \(attempt)"
                    )
                    best = candidate
                } else {
                    writeDebugLog(
                        "[SpicyLyrics] Timing upgrade probe \(attempt) kept \(best.type) for \(trackId)"
                    )
                }
                if best.fidelity == .syllable { break }
            } catch SpicyLyricsServiceError.cancelled {
                throw SpicyLyricsServiceError.cancelled
            } catch {
                writeDebugLog(
                    "[SpicyLyrics] Timing upgrade probe \(attempt) failed for \(trackId): \(error)"
                )
                break
            }
        }
        writeDebugLog(
            "[SpicyLyrics] Selected \(best.type), entries=\(best.entryCount) for \(trackId)"
        )
        return best
    }

    private func isHigherQuality(
        _ lhs: SpicyLyricsResolvedPayload,
        than rhs: SpicyLyricsResolvedPayload
    ) -> Bool {
        if lhs.fidelity != rhs.fidelity { return lhs.fidelity.rawValue > rhs.fidelity.rawValue }
        if lhs.entryCount != rhs.entryCount { return lhs.entryCount > rhs.entryCount }
        return lhs.rendererData.count > rhs.rendererData.count
    }

    private func fetchRemotePayload(
        trackId: String,
        shouldContinue: () -> Bool
    ) throws -> SpicyLyricsResolvedPayload {
        var queuedAttempt = 0
        var authenticationRetries = 0

        while shouldContinue() {
            do {
                let response = try performNetworkQuery(trackId: trackId)
                return try decodeNetworkResponse(response, trackId: trackId)
            } catch SpicyLyricsServiceError.queued {
                let delay = min(10, 2 * pow(1.5, Double(queuedAttempt)))
                queuedAttempt += 1
                writeDebugLog(
                    "[SpicyLyrics] \(trackId) queued; retry \(queuedAttempt) in \(delay)s"
                )
                try waitForRetry(delay, shouldContinue: shouldContinue)
            } catch SpicyLyricsServiceError.authenticationUnavailable {
                guard authenticationRetries < 1 else { throw LyricsError.unknownError }
                authenticationRetries += 1
                spotifyAccessToken = nil
                writeDebugLog("[SpicyLyrics] Waiting once for a fresh token for \(trackId)")
                try waitForRetry(0.5, shouldContinue: shouldContinue)
            }
        }

        throw SpicyLyricsServiceError.cancelled
    }

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let trackId = query.spotifyTrackId
        guard !trackId.isEmpty else {
            writeDebugLog("[SpicyLyrics] Empty track ID")
            throw LyricsError.noSuchSong
        }
        do {
            return try resolvedPayload(
                for: trackId,
                forceRefresh: false,
                shouldContinue: { true }
            ).dto
        } catch let error as LyricsError {
            throw error
        } catch {
            writeDebugLog("[SpicyLyrics] Native lyrics fetch failed for \(trackId): \(error)")
            throw LyricsError.unknownError
        }
    }

    /// Returns the lossless Spicy Lyrics payload used by the local full-screen
    /// renderer. Timed payloads and 404s use the desktop three-day lifetime;
    /// Static payloads expire quickly because a timed AML response may become
    /// available moments later. A queued (inner HTTP 503) response is retried
    /// with desktop's 2s × 1.5 backoff, capped at 10s, until superseded.
    /// This intentionally contains no Spotify access token.
    func rendererPayloadData(
        for trackId: String,
        forceRefresh: Bool = false,
        shouldContinue: () -> Bool = { true }
    ) throws -> Data {
        guard !trackId.isEmpty else { throw LyricsError.noSuchSong }

        return try resolvedPayload(
            for: trackId,
            forceRefresh: forceRefresh,
            shouldContinue: shouldContinue
        ).rendererData
    }

    private func waitForRetry(
        _ delay: TimeInterval,
        shouldContinue: () -> Bool
    ) throws {
        let deadline = Date(timeIntervalSinceNow: delay)
        while Date() < deadline {
            guard shouldContinue() else { throw SpicyLyricsServiceError.cancelled }
            Thread.sleep(forTimeInterval: min(0.1, max(0, deadline.timeIntervalSinceNow)))
        }
    }
}
