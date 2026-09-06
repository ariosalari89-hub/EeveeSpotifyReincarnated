import Foundation

// Initial public contract for the red PC-motion integration fixture.
struct SpicyLyricsAudioAnalysis {
    init?(data: Data) {}
    func multiplier(at position: Double) -> Double { 1 }
}

final class SpicyLyricsAudioAnalysisProvider {
    init(session: URLSession) {}
    func multiplier(trackID: String, position: Double, token: String?) -> Double { 1 }
}
