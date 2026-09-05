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
    private var cover: UIView?
    private var animator: UIViewPropertyAnimator?
    private var dismissOriginal = true
    private var isClosing = false

    private init() {}

    func attach(to controller: UIViewController) {
        present(from: controller, replacesNativeController: true)
    }

    func open(from controller: UIViewController) {
        present(from: controller, replacesNativeController: false)
    }

    /// UIKit keeps the underlying Now Playing window attached during our
    /// fullscreen presentation. Its embedded renderers are not visible work.
    func covers(_ candidate: UIWindow) -> Bool {
        guard let window, window !== candidate, !window.isHidden,
              window.windowLevel > candidate.windowLevel else { return false }
        return window.windowScene === candidate.windowScene
    }

    private func sourceWindow(for controller: UIViewController) -> UIWindow? {
        if let existing = controller.viewIfLoaded?.window
            ?? controller.presentingViewController?.viewIfLoaded?.window
            ?? controller.navigationController?.viewIfLoaded?.window { return existing }
        // viewWillAppear can run before attachment. Only use an unambiguous
        // foreground scene; never accidentally open in another app scene.
        let candidates = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).filter { $0.isKeyWindow && !$0.isHidden }
        return candidates.count == 1 ? candidates.first : nil
    }

    private func present(from controller: UIViewController, replacesNativeController: Bool) {
        precondition(Thread.isMainThread)
        guard window == nil,
              let sourceWindow = sourceWindow(for: controller),
              let scene = sourceWindow.windowScene else { return }
        let screen = SpicyLyricsScreenController()
        let overlay = UIWindow(windowScene: scene)
        overlay.frame = scene.coordinateSpace.bounds
        overlay.windowLevel = .init(rawValue: sourceWindow.windowLevel.rawValue + 1)
        overlay.rootViewController = screen
        screen.loadViewIfNeeded()
        // Size the parent before installing autoresizing children. Growing a
        // zero-sized root would otherwise add a whole screen to the cover.
        screen.view.frame = overlay.bounds
        // Capture the Now Playing surface BEFORE Spotify presents native
        // lyrics. This memory-only cover stays until the renderer is prepared.
        let cover = UIView(frame: overlay.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = sourceWindow.rootViewController?.view.backgroundColor ?? .black
        if let snapshot = sourceWindow.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = cover.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.accessibilityElementsHidden = true
            cover.addSubview(snapshot)
        }
        let cancel = UIButton(type: .system)
        cancel.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        cancel.tintColor = .white
        cancel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        cancel.layer.cornerRadius = 24
        cancel.accessibilityLabel = "Close lyrics"
        cancel.frame = CGRect(x: 16, y: sourceWindow.safeAreaInsets.top + 6, width: 48, height: 48)
        cancel.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        cover.addSubview(cancel)
        screen.view.addSubview(cover)
        let newHost = SpicyLyricsFullscreenHost(
            controller: screen,
            onClose: { [weak self] in self?.close() },
            onReveal: { [weak self, weak overlay] renderer in
                guard let self, let overlay, self.window === overlay else { return }
                self.reveal(renderer, in: overlay)
            }
        )
        guard newHost.attach() else { return }
        source = controller
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow) ?? sourceWindow
        host = newHost
        window = overlay
        self.cover = cover
        dismissOriginal = replacesNativeController
        isClosing = false
        overlay.makeKeyAndVisible()
        sceneObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification, object: scene, queue: .main
        ) { [weak self] _ in self?.close(dismissSource: false) }
        writeDebugLog("[SpicyRenderer] persistent lyrics screen opened")
    }

    private func reveal(_ renderer: UIView, in overlay: UIWindow) {
        guard !isClosing, renderer.alpha < 1, animator == nil else { return }
        renderer.transform = UIAccessibility.isReduceMotionEnabled ? .identity
            : CGAffineTransform(translationX: 0, y: overlay.bounds.height)
        let transition = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.32,
                                                curve: .easeInOut) {
            renderer.alpha = 1
            renderer.transform = .identity
            self.cover?.alpha = 0
        }
        animator = transition
        transition.addCompletion { [weak self, weak overlay] _ in
            guard let self, self.window === overlay, !self.isClosing else { return }
            self.cover?.removeFromSuperview()
            self.cover = nil
            self.animator = nil
        }
        transition.startAnimation()
    }

    func close(dismissSource: Bool = true) {
        precondition(Thread.isMainThread)
        guard let overlay = window, !isClosing else { return }
        isClosing = true
        if let animator {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
        }
        animator = nil
        if dismissSource, dismissOriginal, let original = source {
            if original.presentingViewController != nil {
                original.dismiss(animated: false)
            } else if original.navigationController?.topViewController === original {
                original.navigationController?.popViewController(animated: false)
            }
        }
        guard dismissSource, !UIAccessibility.isReduceMotionEnabled else { finishClose(overlay); return }
        let transition = UIViewPropertyAnimator(duration: 0.26, curve: .easeInOut) {
            overlay.alpha = 0
            overlay.rootViewController?.view.transform = CGAffineTransform(translationX: 0, y: overlay.bounds.height)
        }
        animator = transition
        transition.addCompletion { [weak self, weak overlay] _ in
            guard let self, let overlay, self.window === overlay else { return }
            self.finishClose(overlay)
        }
        transition.startAnimation()
    }

    private func finishClose(_ overlay: UIWindow) {
        host?.detach()
        host = nil
        if let sceneObserver { NotificationCenter.default.removeObserver(sceneObserver) }
        sceneObserver = nil
        overlay.isHidden = true
        overlay.rootViewController = nil
        window = nil
        if previousKeyWindow?.isHidden == false { previousKeyWindow?.makeKey() }
        previousKeyWindow = nil
        source = nil
        cover?.removeFromSuperview()
        cover = nil
        animator = nil
        isClosing = false
        writeDebugLog("[SpicyRenderer] persistent lyrics screen closed")
    }
}
