import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}

var previewVisible = true
var fullScreenVisible = true
let request = SpicyLyricsRequestConsumers()
let preview = request.add { previewVisible }!
let fullscreen = request.add { fullScreenVisible }!
require(request.shouldContinue, "initial request should run")
previewVisible = false
require(request.shouldContinue, "preview detach must not cancel full-screen's shared lyrics")
request.remove(preview)
require(request.shouldContinue, "leader removal must preserve subscribers")
fullScreenVisible = false
require(!request.shouldContinue, "no remaining consumer must cancel the operation")
require(request.add { true } == nil, "late subscriber must not join an operation already cancelling")
request.remove(fullscreen)
let fresh = SpicyLyricsRequestConsumers()
require(fresh.add { true } != nil && fresh.shouldContinue, "late subscriber can start a fresh request")
for _ in 0..<300 {
    let group = SpicyLyricsRequestConsumers()
    let first = group.add { false }!
    let second = group.add { true }!
    require(group.shouldContinue, "one active subscriber is sufficient")
    group.remove(first)
    group.remove(second)
    require(!group.shouldContinue, "removed subscribers must not leak work")
}
print("PASS shared lyric request cancellation, leader handoff and late subscriber isolation")
