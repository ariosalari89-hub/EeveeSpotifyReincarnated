import UIKit
import ObjectiveC.runtime

/// Installs only in verified lyric-content views. The card header/expand/share,
/// artwork, video, title and native playback controls remain Spotify-owned.
enum SpicyLyricsEmbeddedSurfaces {
    private static var association: UInt8 = 0
    private static var installed = false
    private static var enabled: () -> Bool = { false }

    static func install(isEnabled: @escaping () -> Bool) {
        enabled = isEnabled
        guard !installed else { return }
        installed = true
        let targets: [(String, SpicyLyricsSurface)] = [
            ("Lyrics_CardElementImpl.CardContentView", .card),
            ("_TtC22Lyrics_CardElementImpl15CardContentView", .card),
            ("Canvas_CommonImpl.CanvasNowPlayingLyricsView", .inline),
            ("_TtC17Canvas_CommonImpl26CanvasNowPlayingLyricsView", .inline)
        ]
        var seen = Set<ObjectIdentifier>()
        for (name, surface) in targets {
            guard let cls = NSClassFromString(name) as? UIView.Type,
                  seen.insert(ObjectIdentifier(cls)).inserted else { continue }
            for selector in [#selector(UIView.didMoveToWindow), #selector(UIView.layoutSubviews)] {
                guard let method = class_getInstanceMethod(cls, selector),
                      method_getNumberOfArguments(method) == 2,
                      let encoding = method_getTypeEncoding(method), encoding.pointee == 118 else { continue }
                typealias Original = @convention(c) (UIView, Selector) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
                let block: @convention(block) (UIView) -> Void = { view in
                    original(view, selector)
                    update(view, surface: surface)
                }
                let replacement = imp_implementationWithBlock(block)
                // Do not mutate an inherited UIView implementation globally.
                if !class_addMethod(cls, selector, replacement, encoding) {
                    method_setImplementation(method, replacement)
                }
            }
            writeDebugLog("[SpicyEmbedded] installed \(surface.rawValue) in \(name)")
        }
    }

    private static func update(_ view: UIView, surface: SpicyLyricsSurface) {
        let current = objc_getAssociatedObject(view, &association) as? SpicyLyricsEmbeddedHost
        guard enabled(), view.window != nil else {
            current?.detach()
            objc_setAssociatedObject(view, &association, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        if let current { current.layout(); return }
        let host = SpicyLyricsEmbeddedHost(container: view, surface: surface)
        // Associate before adding children, because UIKit may lay out reentrantly.
        objc_setAssociatedObject(view, &association, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        host.attach()
    }
}

private final class SpicyLyricsEmbeddedHost {
    private final class NativeView {
        weak var view: UIView?
        let alpha: CGFloat
        let accessibilityHidden: Bool
        init(_ view: UIView) {
            self.view = view
            alpha = view.alpha
            accessibilityHidden = view.accessibilityElementsHidden
        }
        func restore() {
            view?.alpha = alpha
            view?.accessibilityElementsHidden = accessibilityHidden
        }
    }

    private weak var container: UIView?
    private let controller = UIViewController()
    private let surface: SpicyLyricsSurface
    private var renderer: SpicyLyricsFullscreenHost?
    private var originals = [NativeView]()
    private var updating = false
    private var failed = false

    init(container: UIView, surface: SpicyLyricsSurface) {
        self.container = container
        self.surface = surface
    }

    func attach() {
        guard let container else { return }
        controller.loadViewIfNeeded()
        controller.view.backgroundColor = .clear
        controller.view.accessibilityLabel = surface == .card ? "Spicy Lyrics preview" : "Current lyric"
        controller.view.frame = container.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let owner = owningController(container) { owner.addChild(controller) }
        container.addSubview(controller.view)
        controller.didMove(toParent: controller.parent)
        let host = SpicyLyricsFullscreenHost(controller: controller, surface: surface,
            onClose: { [weak self] in self?.fallBack() },
            onReveal: { renderer in renderer.alpha = 1 },
            onOpen: { [weak self] in
                guard let self, let container = self.container,
                      let owner = self.owningController(container) else { return }
                SpicyLyricsFullscreenCoordinator.shared.open(from: owner)
            })
        renderer = host
        if !host.attach() { fallBack(); return }
        layout()
    }

    func layout() {
        guard !updating, !failed, let container else { return }
        updating = true
        defer { updating = false }
        UIView.performWithoutAnimation {
            // Alpha preserves intrinsic sizes and stack layout. isHidden would
            // collapse the original layout and shrink the replacement to zero.
            for child in container.subviews where child !== controller.view {
                if !originals.contains(where: { $0.view === child }) { originals.append(NativeView(child)) }
                child.alpha = 0
                child.accessibilityElementsHidden = true
            }
            originals.removeAll { $0.view == nil }
            controller.view.frame = container.bounds
            container.bringSubviewToFront(controller.view)
        }
    }

    private func owningController(_ view: UIView) -> UIViewController? {
        var responder: UIResponder? = view.next
        while let next = responder {
            if let controller = next as? UIViewController { return controller }
            responder = next.next
        }
        return view.window?.rootViewController
    }

    private func fallBack() { failed = true; detach() }

    func detach() {
        guard !updating else { return }
        updating = true
        renderer?.detach()
        renderer = nil
        controller.willMove(toParent: nil)
        controller.viewIfLoaded?.removeFromSuperview()
        controller.removeFromParent()
        originals.forEach { $0.restore() }
        originals.removeAll()
        updating = false
    }

    deinit { renderer?.detach() }
}
