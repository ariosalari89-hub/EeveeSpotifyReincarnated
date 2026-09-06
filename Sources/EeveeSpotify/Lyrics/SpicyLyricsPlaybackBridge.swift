import Foundation
import MediaPlayer
import ObjectiveC.runtime
import UIKit
import EeveeSpotifyC

extension Notification.Name {
    static let spicyLyricsPlaybackStateDidChange = Notification.Name(
        "EeveeSpotify.SpicyLyricsPlaybackStateDidChange"
    )
}

/// The Spotify 9.1.76 playback adapter used by every Spicy Lyrics surface.
///
/// The supported ABI was verified against the target executable. Normal state
/// always comes from `-[SPTEsperantoPlayer state]` and the returned
/// `SPTPlayerState`; MediaPlayer is used for display metadata only. There is no
/// second timeline and no selector cascade.
final class SpicyLyricsPlaybackBridge {
    static let shared = SpicyLyricsPlaybackBridge()

    private enum ABI {
        static let playerClass = "SPTEsperantoPlayer"
        static let state = NSSelectorFromString("state")
        static let pause = NSSelectorFromString("pause:")
        static let resume = NSSelectorFromString("resume:")
        static let seek = NSSelectorFromString("seekTo:")
        static let next = NSSelectorFromString("skipToNextTrackWithOptions:")
        static let previous = NSSelectorFromString("skipToPreviousTrackWithOptions:")
        static let shuffle = NSSelectorFromString("setShufflingContext:")
        static let repeatContext = NSSelectorFromString("setRepeatingContext:")
        static let repeatTrack = NSSelectorFromString("setRepeatingTrack:")
    }

    private let queue = DispatchQueue(label: "com.eevee.spicylyrics.playback-state")
    private weak var observedPlayer: AnyObject?
    private var clock = SpicyLyricsPlaybackClock()
    private var lastDiagnosticUptime = 0.0
    private var lastDiagnosticGeneration: UInt64 = 0
    private var loggedABIFailure = false
    private var lifecycleSuspended = false
    // Main-thread presentation cache, limited to the current track identity.
    private var presentedTrackID = ""
    private var presentedTrackFields: [String: String] = [:]

    private init() {}

    /// Player observers are wake-up signals. The payload is decoded from the
    /// supplied SPTPlayerState immediately and reduced on one serial queue.
    func processStateChange(player: AnyObject, state: AnyObject) {
        let observedAt = uptimeSeconds()
        let canonicalState = stateObject(from: player) ?? state
        guard let observation = decodeState(canonicalState, observedAt: observedAt) else {
            logABIFailureOnce("observer supplied no readable SPTPlayerState")
            return
        }
        let supportedPlayer = isSupportedPlayer(player) ? player : nil

        queue.async {
            if let supportedPlayer { self.observedPlayer = supportedPlayer }
            let accepted = self.clock.submit(observation)
            guard accepted else {
                writeDebugLog(
                    "[SpicyRenderer] state rejected stale track="
                    + observation.identity.trackIdentifier
                )
                return
            }
            self.logObservationIfNeeded(observation)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .spicyLyricsPlaybackStateDidChange,
                    object: self
                )
            }
        }
    }

    /// Returns one atomic session envelope: identity, metadata, transport state,
    /// restrictions and clock sequence all describe the same generation.
    func sessionPayload() -> [String: Any]? {
        precondition(Thread.isMainThread)
        let player = authoritativePlayer()
        let observedAt = uptimeSeconds()
        let playerState = player.flatMap { stateObject(from: $0) }

        if let player, let state = playerState,
           let observation = decodeState(state, observedAt: observedAt) {
            queue.sync {
                observedPlayer = player
                if clock.submit(observation) { logObservationIfNeeded(observation) }
            }
        }

        let snapshot = queue.sync { clock.snapshot(at: observedAt) }
        guard let identity = snapshot.identity, identity.isUsable else {
            logABIFailureOnce("no authoritative player session is available")
            return nil
        }

        let track = trackMetadata(
            for: identity.trackIdentifier, duration: snapshot.durationSeconds, state: playerState
        )
        let restrictions = snapshot.restrictions
        var payload: [String: Any] = [
            // Same-device wall clocks measure bounded serialization/delivery
            // age. WebKit anchors that sample to its own monotonic clock.
            "sampledAtEpochMs": (Date().timeIntervalSince1970 - (uptimeSeconds() - observedAt)) * 1000,
            "generation": String(snapshot.generation),
            "sequence": String(snapshot.sequence),
            "trackId": identity.trackIdentifier,
            "playbackId": identity.playbackIdentifier ?? "",
            "sessionId": identity.sessionIdentifier ?? "",
            "positionMs": Int((max(0, snapshot.positionSeconds) * 1000).rounded()),
            "durationMs": Int((max(0, snapshot.durationSeconds) * 1000).rounded()),
            "playbackRate": snapshot.playbackRate,
            "backgroundMotionMultiplier": SpicyLyricsAudioAnalysisProvider.shared.multiplier(
                trackID: identity.trackIdentifier, position: snapshot.positionSeconds, token: spotifyAccessToken),
            "isPlaying": snapshot.isPlaying,
            "isPaused": snapshot.isPaused,
            "isLoading": snapshot.isLoading,
            "isBuffering": snapshot.isBuffering,
            "isAdvancing": snapshot.isAdvancing,
            "requiresFreshObservation": snapshot.requiresFreshObservation,
            "shuffleEnabled": snapshot.shuffleEnabled,
            "repeatMode": snapshot.repeatMode.rawValue,
            "canSeek": !restrictions.disallowSeeking,
            "canPause": !restrictions.disallowPausing,
            "canResume": !restrictions.disallowResuming,
            "canGoPrevious": !restrictions.disallowSkippingToPreviousTrack,
            "canGoNext": !restrictions.disallowSkippingToNextTrack,
            "canToggleShuffle": !restrictions.disallowTogglingShuffle,
            "canToggleRepeatContext": !restrictions.disallowTogglingRepeatContext,
            "canToggleRepeatTrack": !restrictions.disallowTogglingRepeatTrack,
            "track": track
        ]
        let controls = EeveeSpicyReadControls(playerState)
        for (key, value) in controls { payload[key] = value }
        // The native three-state getter is one coherent observation. Do not
        // rebuild it from the independently sampled clock flag: during Smart
        // Shuffle -> Off that flag can still say Shuffle for another callback.
        if controls["shuffleMode"] == nil {
            let smart = (controls["smartShuffleEnabled"] as? NSNumber)?.boolValue ?? false
            payload["shuffleMode"] = smart ? "smart" : (snapshot.shuffleEnabled ? "shuffle" : "off")
        }
        return payload
    }

    func suspendPlaybackClock() {
        guard !lifecycleSuspended else { return }
        lifecycleSuspended = true
        let now = uptimeSeconds()
        queue.sync { clock.suspend(at: now) }
        writeDebugLog("[SpicyRenderer] lifecycle suspended")
    }

    func resumeAwaitingObservation() {
        guard lifecycleSuspended else { return }
        lifecycleSuspended = false
        let now = uptimeSeconds()
        queue.sync { clock.resumeAwaitingObservation(at: now) }
        writeDebugLog("[SpicyRenderer] lifecycle awaiting authoritative state")
    }

    @discardableResult
    func perform(command: String, value: Double? = nil) -> Bool {
        precondition(Thread.isMainThread)
        guard let player = authoritativePlayer(),
              let payload = sessionPayload() else {
            writeDebugLog("[SpicyRenderer] command \(command) rejected: player unavailable")
            return false
        }

        if command != "seek" {
            let nativeResult = EeveeSpicyPerformControl(command, stateObject(from: player))
            if nativeResult >= 0 {
                let dispatched = nativeResult == 1
                writeDebugLog("[SpicyControls] command=\(command) native dispatched=\(dispatched)")
                if dispatched { scheduleObservationBurst() }
                return dispatched
            }
        }

        let accepted: Bool
        switch command {
        case "togglePlay":
            let paused = (payload["isPaused"] as? Bool) ?? true
            accepted = setPlaying(paused, player: player, payload: payload)
        case "play":
            accepted = setPlaying(true, player: player, payload: payload)
        case "pause":
            accepted = setPlaying(false, player: player, payload: payload)
        case "seek":
            let allowed = (payload["canSeek"] as? Bool) ?? false
            accepted = allowed && invokeDouble(
                player,
                selector: ABI.seek,
                value: max(0, value ?? 0)
            )
        case "next":
            let allowed = (payload["canGoNext"] as? Bool) ?? false
            accepted = allowed && invokeObject(player, selector: ABI.next, value: nil)
        case "previous":
            let allowed = (payload["canGoPrevious"] as? Bool) ?? false
            accepted = allowed && invokeObject(player, selector: ABI.previous, value: nil)
        case "toggleShuffle":
            let allowed = (payload["canToggleShuffle"] as? Bool) ?? false
            let current = (payload["shuffleEnabled"] as? Bool) ?? false
            accepted = allowed && invokeBoolean(
                player,
                selector: ABI.shuffle,
                value: !current
            )
        case "cycleRepeat":
            accepted = cycleRepeat(player: player, payload: payload)
        default:
            accepted = false
        }

        writeDebugLog("[SpicyRenderer] command \(command) dispatched=\(accepted)")
        if accepted { scheduleObservationBurst() }
        return accepted
    }

    private func setPlaying(
        _ shouldPlay: Bool,
        player: AnyObject,
        payload: [String: Any]
    ) -> Bool {
        let allowed = shouldPlay
            ? ((payload["canResume"] as? Bool) ?? false)
            : ((payload["canPause"] as? Bool) ?? false)
        guard allowed else { return false }
        return invokeObject(
            player,
            selector: shouldPlay ? ABI.resume : ABI.pause,
            value: nil
        )
    }

    private func cycleRepeat(player: AnyObject, payload: [String: Any]) -> Bool {
        let current = SpicyLyricsRepeatMode(
            rawValue: payload["repeatMode"] as? String ?? "off"
        ) ?? .off
        let canContext = (payload["canToggleRepeatContext"] as? Bool) ?? false
        let canTrack = (payload["canToggleRepeatTrack"] as? Bool) ?? false

        switch current {
        case .off:
            guard canContext else { return false }
            return invokeBoolean(
                player,
                selector: ABI.repeatContext,
                value: true
            )
        case .context:
            if canTrack {
                return invokeBoolean(
                    player,
                    selector: ABI.repeatTrack,
                    value: true
                )
            }
            guard canContext else { return false }
            return invokeBoolean(
                player,
                selector: ABI.repeatContext,
                value: false
            )
        case .track:
            // Repeat-track is layered on top of repeat-context in the verified
            // 9.1.76 state. Disabling track first reaches context. When Spotify
            // also permits context changes, continue to off; otherwise retain
            // the valid context mode instead of trapping the control.
            guard canTrack else { return false }
            let trackAccepted = invokeBoolean(
                player,
                selector: ABI.repeatTrack,
                value: false
            )
            guard trackAccepted else { return false }
            guard canContext else { return true }
            return invokeBoolean(
                player,
                selector: ABI.repeatContext,
                value: false
            )
        }
    }

    private func authoritativePlayer() -> AnyObject? {
        precondition(Thread.isMainThread)
        let typedPlayer = statefulPlayer.map { $0 as AnyObject }
        if let typedPlayer, isSupportedPlayer(typedPlayer) { return typedPlayer }
        let captured = queue.sync { observedPlayer }
        if let captured, isSupportedPlayer(captured) { return captured }
        return nil
    }

    private func isSupportedPlayer(_ player: AnyObject) -> Bool {
        guard let expectedClass = NSClassFromString(ABI.playerClass),
              let object = player as? NSObject else { return false }
        return object.isKind(of: expectedClass) && player.responds(to: ABI.state)
    }

    private func stateObject(from player: AnyObject) -> AnyObject? {
        guard player.responds(to: ABI.state) else { return nil }
        return player.value(forKey: "state") as AnyObject?
    }

    private func decodeState(
        _ state: AnyObject,
        observedAt: TimeInterval
    ) -> SpicyLyricsPlaybackObservation? {
        guard let trackObject = safeRead(state, key: "track") as AnyObject?,
              let trackURI = extractURI(from: trackObject),
              let trackIdentifier = spotifyTrackID(from: trackURI),
              let position = safeDouble(state, key: "position"),
              let duration = safeDouble(state, key: "duration") else {
            return nil
        }

        let options = safeRead(state, key: "options") as AnyObject?
        let restrictionsObject = safeRead(state, key: "restrictions") as AnyObject?
        let repeatsTrack = safeBool(options, key: "repeatingTrack") ?? false
        let repeatsContext = safeBool(options, key: "repeatingContext") ?? false
        let repeatMode: SpicyLyricsRepeatMode = repeatsTrack
            ? .track
            : (repeatsContext ? .context : .off)

        return SpicyLyricsPlaybackObservation(
            identity: SpicyLyricsPlaybackIdentity(
                trackIdentifier: trackIdentifier,
                playbackIdentifier: safeIdentifier(safeRead(state, key: "playbackId")),
                sessionIdentifier: safeIdentifier(safeRead(state, key: "sessionID"))
            ),
            positionSeconds: max(0, position),
            durationSeconds: max(0, duration),
            playbackRate: max(0.01, safeDouble(state, key: "playbackSpeed") ?? 1),
            isPlaying: safeBool(state, key: "isPlaying") ?? false,
            isPaused: safeBool(state, key: "isPaused") ?? true,
            isLoading: safeBool(state, key: "isLoading") ?? false,
            isBuffering: safeBool(state, key: "isBuffering") ?? false,
            shuffleEnabled: safeBool(options, key: "shufflingContext") ?? false,
            repeatMode: repeatMode,
            restrictions: decodeRestrictions(restrictionsObject),
            sourceTimestampSeconds: timestampSeconds(safeRead(state, key: "timestamp")),
            observedAtUptimeSeconds: observedAt
        )
    }

    private func decodeRestrictions(_ object: AnyObject?) -> SpicyLyricsPlaybackRestrictions {
        SpicyLyricsPlaybackRestrictions(
            disallowSeeking: safeBool(object, key: "disallowSeeking") ?? false,
            disallowPausing: safeBool(object, key: "disallowPausing") ?? false,
            disallowResuming: safeBool(object, key: "disallowResuming") ?? false,
            disallowSkippingToPreviousTrack: safeBool(
                object,
                key: "disallowSkippingToPreviousTrack"
            ) ?? false,
            disallowSkippingToNextTrack: safeBool(
                object,
                key: "disallowSkippingToNextTrack"
            ) ?? false,
            disallowTogglingShuffle: safeBool(
                object,
                key: "disallowTogglingShuffle"
            ) ?? false,
            disallowTogglingRepeatContext: safeBool(
                object,
                key: "disallowTogglingRepeatContext"
            ) ?? false,
            disallowTogglingRepeatTrack: safeBool(
                object,
                key: "disallowTogglingRepeatTrack"
            ) ?? false
        )
    }

    private func invokeObject(_ target: AnyObject, selector: Selector, value: AnyObject?) -> Bool {
        guard target.responds(to: selector),
              methodArgumentType(target, selector: selector) == "@" else {
            return false
        }
        EeveeInvokeObjectArg(target, selector, value)
        return true
    }

    private func invokeDouble(_ target: AnyObject, selector: Selector, value: Double) -> Bool {
        guard value.isFinite,
              target.responds(to: selector),
              methodArgumentType(target, selector: selector) == "d" else {
            return false
        }
        EeveeSBInvokeSeekDouble(target, selector, value)
        return true
    }

    private func invokeBoolean(_ target: AnyObject, selector: Selector, value: Bool) -> Bool {
        EeveeSpicySetBooleanOption(target, selector, value)
    }

    private func methodArgumentType(_ target: AnyObject, selector: Selector) -> String? {
        guard let method = class_getInstanceMethod(object_getClass(target), selector),
              method_getNumberOfArguments(method) == 3,
              let rawType = method_copyArgumentType(method, 2) else {
            return nil
        }
        defer { free(rawType) }
        let raw = String(cString: rawType)
        // Strip Objective-C qualifiers such as const/in/out before comparing.
        return String(raw.drop(while: { "rnNoORV".contains($0) }))
    }

    private func scheduleObservationBurst() {
        for delay in [0.04, 0.12, 0.3, 0.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NotificationCenter.default.post(
                    name: .spicyLyricsPlaybackStateDidChange,
                    object: self
                )
            }
        }
    }

    private func trackMetadata(
        for expectedTrackID: String, duration: Double, state: AnyObject?
    ) -> [String: Any] {
        precondition(Thread.isMainThread)
        if presentedTrackID != expectedTrackID {
            presentedTrackID = expectedTrackID
            presentedTrackFields = [:]
        }
        let nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        // The observer can supply the supported player before the legacy
        // Now Playing service is captured. Read display data from the very
        // same SPTPlayerState used for this session's identity and clock.
        let stateTrack = safeRead(state, key: "track") as AnyObject?
        let legacyTrack = safeRead(statefulPlayer as AnyObject?, key: "currentTrack") as AnyObject?
        let tracks = [stateTrack, legacyTrack].compactMap { $0 }.filter {
            extractURI(from: $0).flatMap(spotifyTrackID) == expectedTrackID
        }
        func trackField(_ key: String) -> String? {
            tracks.lazy.compactMap { self.nonEmpty(self.safeRead($0, key: key) as? String) }.first
        }
        var metadata: [String: String] = [:]
        for track in tracks.reversed() {
            for (key, value) in safeRead(track, key: "metadata") as? [String: String] ?? [:] {
                if let value = nonEmpty(value) { metadata[key] = value }
            }
        }
        let trackTitle = trackField("trackTitle")
        let trackArtist = trackField("artistName")
        let capturedMatches = capturedTrackId == expectedTrackID
        let nowPlayingTitle = nonEmpty(nowPlaying[MPMediaItemPropertyTitle] as? String)
        let nowPlayingArtist = nonEmpty(nowPlaying[MPMediaItemPropertyArtist] as? String)
        let knownTitle = trackTitle
            ?? nonEmpty(presentedTrackFields["title"])
            ?? (capturedMatches ? nonEmpty(capturedTrackTitle) : nil)
        let knownArtist = trackArtist
            ?? nonEmpty(presentedTrackFields["artist"])
            ?? (capturedMatches ? nonEmpty(capturedArtistName) : nil)
        // MPNowPlayingInfoCenter can lag one turn behind a rapid skip. Only
        // borrow its optional fields when its title/artist agree with the
        // track that came from the same authoritative player state.
        let nowPlayingMatches = knownTitle != nil
            && knownArtist != nil
            && nowPlayingTitle == knownTitle
            && nowPlayingArtist == knownArtist
        let title = knownTitle ?? "Unknown track"
        let artist = knownArtist ?? "Unknown artist"
        let album = trackField("albumTitle")
            ?? nonEmpty(metadata["album_title"])
            ?? (nowPlayingMatches
                ? nonEmpty(nowPlaying[MPMediaItemPropertyAlbumTitle] as? String)
                : nil)
            ?? nonEmpty(presentedTrackFields["album"])
            ?? ""
        let artwork = normalizedArtworkURL(from: metadata)
            ?? (nowPlayingMatches
                ? artworkDataURL(from: nowPlaying[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
                : nil)
            ?? nonEmpty(presentedTrackFields["artwork"])
            ?? ""
        let color = trackField("extractedColorHex")
            ?? nonEmpty(presentedTrackFields["dominantColor"]) ?? ""
        // Partial observations may improve one field without repeating every
        // other field. Never cache fallback labels or borrow from another URI.
        presentedTrackFields = [
            "title": knownTitle ?? "", "artist": knownArtist ?? "", "album": album,
            "artwork": artwork, "dominantColor": color
        ]

        return [
            "id": expectedTrackID,
            "uri": "spotify:track:\(expectedTrackID)",
            "title": title,
            "artist": artist,
            "album": album,
            "durationMs": Int((max(0, duration) * 1000).rounded()),
            "artwork": artwork,
            "dominantColor": color
        ]
    }

    private func logObservationIfNeeded(_ observation: SpicyLyricsPlaybackObservation) {
        let now = observation.observedAtUptimeSeconds
        let snapshot = clock.snapshot(at: now)
        guard snapshot.generation != lastDiagnosticGeneration
                || now - lastDiagnosticUptime >= 5
                || snapshot.isPaused != observation.isPaused else {
            return
        }
        lastDiagnosticGeneration = snapshot.generation
        lastDiagnosticUptime = now
        let formattedPosition = String(format: "%.3f", snapshot.positionSeconds)
        writeDebugLog(
            "[SpicyRenderer] state generation=\(snapshot.generation) "
            + "sequence=\(snapshot.sequence) track=\(observation.identity.trackIdentifier) "
            + "position=\(formattedPosition) "
            + "playing=\(snapshot.isPlaying) paused=\(snapshot.isPaused) "
            + "buffering=\(snapshot.isBuffering)"
        )
    }

    private func logABIFailureOnce(_ message: String) {
        queue.async {
            guard !self.loggedABIFailure else { return }
            self.loggedABIFailure = true
            writeDebugLog("[SpicyRenderer] Spotify 9.1.76 adapter unavailable: \(message)")
        }
    }

    private func safeRead(_ object: AnyObject?, key: String) -> Any? {
        guard let object, object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    private func safeDouble(_ object: AnyObject?, key: String) -> Double? {
        guard let value = safeRead(object, key: key) as? NSNumber else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    private func safeBool(_ object: AnyObject?, key: String) -> Bool? {
        let value = safeRead(object, key: key)
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return value as? Bool
    }

    private func safeIdentifier(_ value: Any?) -> String? {
        if let string = value as? String { return nonEmpty(string) }
        if let uuid = value as? UUID { return uuid.uuidString }
        if let uuid = value as? NSUUID { return uuid.uuidString }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func timestampSeconds(_ value: Any?) -> TimeInterval? {
        if let date = value as? Date { return date.timeIntervalSince1970 }
        if let date = value as? NSDate { return date.timeIntervalSince1970 }
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw > 0 else { return nil }
        return raw > 10_000_000_000 ? raw / 1000 : raw
    }

    private func extractURI(from track: AnyObject) -> String? {
        if let string = safeRead(track, key: "URI") as? String { return string }
        if let url = safeRead(track, key: "URI") as? URL { return url.absoluteString }
        if let string = safeRead(track, key: "uri") as? String { return string }
        return nil
    }

    private func spotifyTrackID(from uri: String) -> String? {
        if uri.hasPrefix("spotify:track:") {
            return nonEmpty(String(uri.dropFirst("spotify:track:".count)))
        }
        if let range = uri.range(of: "/track/") {
            let tail = String(uri[range.upperBound...])
            return tail.split(separator: "?").first.map(String.init).flatMap(nonEmpty)
        }
        return nil
    }

    private func artworkDataURL(from artwork: MPMediaItemArtwork?) -> String? {
        guard let image = artwork?.image(at: CGSize(width: 640, height: 640)) else { return nil }
        let size = CGSize(width: 640, height: 640)
        let renderer = UIGraphicsImageRenderer(size: size)
        let square = renderer.image { _ in
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(
                x: (size.width - drawSize.width) / 2,
                y: (size.height - drawSize.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        guard let data = square.jpegData(compressionQuality: 0.86) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private func normalizedArtworkURL(from metadata: [String: String]) -> String? {
        let keys = [
            "image_xlarge_url",
            "image_large_url",
            "image_url",
            "album_image_url",
            "cover_url",
            "image_uri"
        ]
        guard let raw = keys.lazy.compactMap({ self.nonEmpty(metadata[$0]) }).first else {
            return nil
        }
        if raw.hasPrefix("spotify:image:") {
            let imageIdentifier = raw.replacingOccurrences(of: "spotify:image:", with: "")
            return "https://i.scdn.co/image/\(imageIdentifier)"
        }
        return raw
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func uptimeSeconds() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
