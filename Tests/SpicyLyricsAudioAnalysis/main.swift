import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let firstID = String(repeating: "A", count: 22), secondID = String(repeating: "B", count: 22)
let analysisJSON = """
{"track":{"tempo":180,"loudness":-20},
 "sections":[{"start":0,"duration":2,"tempo":60,"loudness":-40},
             {"start":10,"duration":2,"tempo":360,"loudness":0}],
 "beats":[{"start":0,"duration":1,"confidence":0.8},
          {"start":3,"duration":1,"confidence":0.4},
          {"start":10,"duration":1,"confidence":1}]}
""".data(using: .utf8)!

// Independently calculated from the pinned PC BackgroundAnimationController:
// tempo/120 * (.5 + max(0,(dB+40)/40)*.7), plus a confident beat's
// 1.5 * exp(-5 * progress) * confidence; final clamp .1...3.
let analysis = SpicyLyricsAudioAnalysis(data: analysisJSON)!
for (time, expected) in [(0.0, 1.45), (0.5, 0.3485019983486786), (1.0, 0.25),
                         (2.0, 1.275), (3.0, 1.275), (10.0, 3.0), (12.0, 1.275)] {
    expect(abs(analysis.multiplier(at: time) - expected) < 0.00000001,
           "PC motion formula at \(time)s must be \(expected), got \(analysis.multiplier(at: time))")
}
expect(SpicyLyricsAudioAnalysis(data: Data("{}".utf8)) == nil, "missing analysis must not become a fabricated beat grid")
expect(SpicyLyricsAudioAnalysis(data: Data("{\"track\":{\"tempo\":120,\"loudness\":-20},\"sections\":[],\"beats\":[{\"start\":0,\"duration\":0,\"confidence\":1}]}".utf8)) == nil,
       "invalid beat duration must not reach clock integration")

// URLSession is the external boundary. The shipping owner, decoding and
// generation checks remain real; no service collaborators are replaced.
final class AnalysisProtocol: URLProtocol {
    static let lock = NSLock()
    static var pending: [AnalysisProtocol] = []
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.pending.append(self); Self.lock.unlock()
    }
    override func stopLoading() {}
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    static func complete(_ index: Int, status: Int = 200, data: Data = analysisJSON) {
        lock.lock(); let item = pending[index]; lock.unlock()
        item.client?.urlProtocol(item, didReceive: HTTPURLResponse(url: item.request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        item.client?.urlProtocol(item, didLoad: data)
        item.client?.urlProtocolDidFinishLoading(item)
    }
}
func until(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(condition(), message)
}
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [AnalysisProtocol.self]
let service = SpicyLyricsAudioAnalysisProvider(session: URLSession(configuration: configuration))
expect(service.multiplier(trackID: firstID, position: 0, token: nil) == 1 && AnalysisProtocol.count == 0,
       "no authorization must remain a nonblocking, request-free default")
expect(service.multiplier(trackID: "spotify:local:test", position: 0, token: "qa-only") == 1 && AnalysisProtocol.count == 0,
       "local audio must never be uploaded or queried for analysis")
_ = service.multiplier(trackID: firstID, position: 0, token: "qa-only")
until("a catalog track must request native Spotify analysis") { AnalysisProtocol.count == 1 }
for _ in 0..<20 { _ = service.multiplier(trackID: firstID, position: 0, token: "qa-only") }
expect(AnalysisProtocol.count == 1, "frequent playback samples must share one analysis request")
let request = AnalysisProtocol.requests[0]
expect(request.url?.absoluteString == "https://spclient.wg.spotify.com/audio-attributes/v1/audio-analysis/\(firstID)?format=json" &&
       request.value(forHTTPHeaderField: "Authorization") == "Bearer qa-only" && request.httpBody == nil,
       "only the fixed first-party catalog endpoint may receive existing native authorization")
AnalysisProtocol.complete(0)
until("the current track must receive its verified PC multiplier") {
    abs(service.multiplier(trackID: firstID, position: 0, token: "qa-only") - 1.45) < 0.00001
}
expect(abs(service.multiplier(trackID: firstID, position: 3, token: "qa-only") - 1.275) < 0.00001 && AnalysisProtocol.count == 1,
       "progress must use the current position without re-fetching or inventing beat timing")
_ = service.multiplier(trackID: secondID, position: 0, token: "qa-only")
until("the changed track must own a separate request") { AnalysisProtocol.count == 2 }
_ = service.multiplier(trackID: firstID, position: 0, token: "qa-only")
until("switching back must use a new request generation") { AnalysisProtocol.count == 3 }
AnalysisProtocol.complete(2, status: 404)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
AnalysisProtocol.complete(1)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
expect(service.multiplier(trackID: firstID, position: 0, token: "qa-only") == 1 && AnalysisProtocol.count == 3,
       "a stale success must not replace the current track's missing-analysis default or restart failed requests")
print("PASS PC tempo/loudness/beat math, confidence thresholds, native request ownership, stale results and missing-analysis fallback")
