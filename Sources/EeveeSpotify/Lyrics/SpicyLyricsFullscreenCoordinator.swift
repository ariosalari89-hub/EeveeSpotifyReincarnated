import UIKit

private final class SpicyLyricsScreenController: UIViewController {
    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
        view.accessibilityViewIsModal = true
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
}

/// The user owns the lifetime of this lyrics screen. Spotify's original
/// fullscreen controller belongs to one track and can disappear on a skip.
/// A scene-bound window lets that controller finish its normal lifecycle
/// without destroying the renderer or cancelling the next lyrics request.
final class SpicyLyricsFullscreenCoordinator {
    static let shared = SpicyLyricsFullscreenCoordinator()

    private var window: UIWindow?
    private var host: SpicyLyricsFullscreenHost?
    private weak var source: UIViewController?
    private weak var previousKeyWindow: UIWindow?
    private var sceneObserver: NSObjectProtocol?

    private init() {}

    func attach(to controller: UIViewController) {
        precondition(Thread.isMainThread)
        guard window == nil,
              let sourceWindow = controller.viewIfLoaded?.window,
              let scene = sourceWindow.windowScene else { return }
        let screen = SpicyLyricsScreenController()
        let overlay = UIWindow(windowScene: scene)
        overlay.frame = scene.coordinateSpace.bounds
        overlay.windowLevel = .init(rawValue: sourceWindow.windowLevel.rawValue + 1)
        overlay.rootViewController = screen
        let newHost = SpicyLyricsFullscreenHost(
            controller: screen,
            onClose: { [weak self] in self?.close() },
            onReveal: { [weak self, weak overlay] in
                guard let self, let overlay, self.window === overlay else { return }
                overlay.makeKeyAndVisible()
            }
        )
        screen.loadViewIfNeeded()
        guard newHost.attach() else { return }
        source = controller
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow) ?? sourceWindow
        host = newHost
        window = overlay
        sceneObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification, object: scene, queue: .main
        ) { [weak self] _ in self?.close(dismissSource: false) }
        writeDebugLog("[SpicyRenderer] persistent lyrics screen opened")
    }

    func close(dismissSource: Bool = true) {
        precondition(Thread.isMainThread)
        guard let overlay = window else { return }
        host?.detach()
        host = nil
        if let sceneObserver { NotificationCenter.default.removeObserver(sceneObserver) }
        sceneObserver = nil
        overlay.isHidden = true
        overlay.rootViewController = nil
        window = nil
        if previousKeyWindow?.isHidden == false { previousKeyWindow?.makeKey() }
        previousKeyWindow = nil
        let original = source
        source = nil
        if dismissSource, let original, original.viewIfLoaded?.window != nil {
            if original.presentingViewController != nil {
                original.dismiss(animated: false)
            } else if original.navigationController?.topViewController === original {
                original.navigationController?.popViewController(animated: false)
            }
        }
        writeDebugLog("[SpicyRenderer] persistent lyrics screen closed")
    }
}
