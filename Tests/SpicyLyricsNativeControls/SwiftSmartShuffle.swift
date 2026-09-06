import Foundation

// Spotify's handler is a native Swift root class, not an NSObject subclass.
// Keep this boundary fixture native Swift so NSObject reflection cannot hide
// the methodSignatureForSelector: failure seen on the physical phone.
final class QASwiftSmartShuffle {
    @objc var mode: UInt = 0
    @objc var offeredPicker = false
    @objc var rejectChange = false
    @objc var explicitCalls: UInt = 0

    @objc(checkIsEntitySmartShuffled:)
    func checkIsEntitySmartShuffled(_ url: NSURL) -> Bool { mode == 2 }

    @objc(shuffleStateWithEntityURL:)
    func shuffleStateWithEntityURL(_ url: NSURL) -> UInt { mode }

    @objc(shuffleStateWithPlayerState:)
    func shuffleStateWithPlayerState(_ state: NSObject) -> UInt { mode }

    @objc(setShuffleState:for:showConfirmationUI:completion:)
    func setShuffleState(_ next: UInt, for url: NSURL, showConfirmationUI: Bool,
                         completion: @escaping (Int) -> Void) {
        precondition(url.absoluteString == "spotify:playlist:test")
        offeredPicker = showConfirmationUI
        explicitCalls += 1
        if !rejectChange { mode = next }
        completion(rejectChange ? 1 : 0)
    }
}

@_cdecl("SpicyQAMakeSwiftSmartShuffle")
public func makeSwiftSmartShuffle() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(QASwiftSmartShuffle()).toOpaque()
}
