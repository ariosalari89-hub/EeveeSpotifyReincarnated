import Foundation

/// PC BackgroundAnimationController at 4576d022b39e98291d71c75b0d4d355bcc332ced.
/// Analysis affects ambient paint only, never playback or lyric timestamps.
struct SpicyLyricsAudioAnalysis {
    private struct Track: Decodable { let tempo: Double; let loudness: Double }
    private struct Section: Decodable {
        let start: Double; let duration: Double; let tempo: Double; let loudness: Double
    }
    private struct Beat: Decodable { let start: Double; let duration: Double; let confidence: Double }
    private struct Payload: Decodable { let track: Track; let sections: [Section]; let beats: [Beat] }
    private let payload: Payload

    init?(data: Data) {
        guard data.count <= 4 * 1_024 * 1_024,
              let decoded = try? JSONDecoder().decode(Payload.self, from: data),
              decoded.track.tempo.isFinite, decoded.track.tempo >= 0, decoded.track.loudness.isFinite,
              decoded.sections.count <= 8192, decoded.beats.count <= 32768,
              decoded.sections.allSatisfy({ $0.start.isFinite && $0.start >= 0 && $0.duration.isFinite && $0.duration > 0 &&
                  $0.tempo.isFinite && $0.tempo >= 0 && $0.loudness.isFinite }),
              decoded.beats.allSatisfy({ $0.start.isFinite && $0.start >= 0 && $0.duration.isFinite && $0.duration > 0 &&
                  $0.confidence.isFinite && $0.confidence >= 0 && $0.confidence <= 1 }) else { return nil }
        payload = decoded
    }

    func multiplier(at position: Double) -> Double {
        guard position.isFinite else { return 1 }
        let section = payload.sections.first { position >= $0.start && position < $0.start + $0.duration }
        let tempo = section?.tempo ?? payload.track.tempo
        let loudness = section?.loudness ?? payload.track.loudness
        let loudnessFactor = 0.5 + max(0, (loudness + 40) / 40) * 0.7
        var speed = (tempo / 120) * loudnessFactor
        if let beat = payload.beats.first(where: { position >= $0.start && position < $0.start + $0.duration }),
           beat.confidence > 0.4 {
            speed += 1.5 * exp(-5 * (position - beat.start) / beat.duration) * beat.confidence
        }
        return max(0.1, min(speed, 3))
    }
}

/// One native request/cache owner for all lyric surfaces. A track change cancels
/// the old request; its generation can never publish over the new track. Like
/// the PC's current-track null cache, failures stay at default until track change.
final class SpicyLyricsAudioAnalysisProvider {
    static let shared: SpicyLyricsAudioAnalysisProvider = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return SpicyLyricsAudioAnalysisProvider(session: URLSession(configuration: configuration,
            delegate: AudioAnalysisRedirectPolicy(), delegateQueue: nil))
    }()

    private let session: URLSession
    private var activeID: String?
    private var generation: UInt64 = 0
    private var task: URLSessionDataTask?
    private var analysis: SpicyLyricsAudioAnalysis?
    private var attempted = false

    init(session: URLSession) { self.session = session }

    func multiplier(trackID: String, position: Double, token: String?) -> Double {
        precondition(Thread.isMainThread)
        let characters = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let validID = trackID.count == 22 && trackID.unicodeScalars.allSatisfy { characters.contains($0) } ? trackID : nil
        if activeID != validID {
            generation &+= 1
            task?.cancel(); task = nil
            analysis = nil; attempted = false; activeID = validID
        }
        guard let validID else { return 1 }
        if let analysis { return analysis.multiplier(at: position) }
        guard !attempted, let token, !token.isEmpty else { return 1 }
        attempted = true
        let requestGeneration = generation
        let url = URL(string: "https://spclient.wg.spotify.com/audio-attributes/v1/audio-analysis/\(validID)?format=json")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request) { [weak self] data, response, error in
            // Decode away from the UI queue. Neither the token nor raw analysis
            // is serialized to WebKit, written to disk or included in logs.
            let parsed: SpicyLyricsAudioAnalysis?
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data {
                parsed = SpicyLyricsAudioAnalysis(data: data)
            } else { parsed = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == requestGeneration, self.activeID == validID else { return }
                self.task = nil
                self.analysis = parsed
            }
        }
        task?.resume()
        return 1
    }
}

private final class AudioAnalysisRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Existing authorization belongs only to the fixed Spotify endpoint.
        completionHandler(nil)
    }
}
