import Orion
import UIKit

class LyricsFullscreenViewControllerHook: ClassHook<UIViewController> {
    typealias Group = BaseLyricsGroup
    
    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.FullscreenViewController"
        case .lastAvailableiOS15: return "Lyrics_FullscreenPageImpl.FullscreenViewController"
        default: return "Lyrics_FullscreenElementPageImpl.FullscreenElementViewController"
        }
    }

    func viewDidLoad() {
        orig.viewDidLoad()

        if EeveeSpotify.hookTarget == .v91 {
            if UserDefaults.lyricsSource == .spicylyrics {
                SpicyLyricsFullscreenCoordinator.shared.attach(to: target)
            }
            return
        }
        
        if UserDefaults.lyricsSource == .musixmatch
            && lyricsState.fallbackError == nil
            && !lyricsState.wasRomanized
            && !lyricsState.isEmpty {
            return
        }
        
        if EeveeSpotify.hookTarget == .latest {
            guard let fullscreenView = WindowHelper.shared.findFirstSubview(
                "Lyrics_FullscreenElementPageImpl.FullscreenView",
                in: target.view
            ) else {
                return
            }
            
            let controlsView = Ivars<UIView>(fullscreenView).controlsView
            let contextMenuButtonContainer = Ivars<UIView>(controlsView).contextMenuButtonContainer
            
            if let contextButton = contextMenuButtonContainer.subviews(
                matching: "Encore6Button"
            ).first as? UIControl {
                contextButton.isEnabled = false
            }
            
            return
        }
        
        let headerView = Ivars<UIView>(target.view).headerView
        
        if let reportButton = headerView.subviews(matching: "EncoreButton")[1] as? UIButton {
            reportButton.isEnabled = false
        }
    }

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        guard EeveeSpotify.hookTarget == .v91,
              UserDefaults.lyricsSource == .spicylyrics else { return }
        // viewDidLoad performs the normal pre-warm. This idempotent call also
        // covers a reused controller whose previous host was detached.
        SpicyLyricsFullscreenCoordinator.shared.attach(to: target)
    }

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        guard EeveeSpotify.hookTarget == .v91,
              UserDefaults.lyricsSource == .spicylyrics else { return }
        // The window scene is available even if viewDidLoad ran off-window.
        SpicyLyricsFullscreenCoordinator.shared.attach(to: target)
    }
}
