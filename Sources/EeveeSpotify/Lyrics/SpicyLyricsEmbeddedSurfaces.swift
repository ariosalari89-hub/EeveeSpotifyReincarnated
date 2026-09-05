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
            ("_TtC17Canvas_CommonImpl26CanvasNowPlayingLyricsView", .inline),
            ("Canvas_CommonImpl.CanvasNowPlayingLyricsElementView", .inline),
            ("_TtC17Canvas_CommonImpl33CanvasNowPlayingLyricsElementView", .inline),
            ("Lyrics_NPVContainerKit.LyricsContainerView", .inline),
            ("_TtC22Lyrics_NPVContainerKit19LyricsContainerView", .inline),
            ("NowPlaying_ContentLayersImpl.LegacyLyricsContainerView", .inline),
            ("_TtC28NowPlaying_ContentLayersImpl25LegacyLyricsContainerView", .inline)
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
            let added = #selector(UIView.didAddSubview(_:))
            if let method = class_getInstanceMethod(cls, added), method_getNumberOfArguments(method) == 3 {
                typealias Original = @convention(c) (UIView, Selector, UIView) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
                let block: @convention(block) (UIView, UIView) -> Void = { view, child in
                    original(view, added, child)
                    update(view, surface: surface)
                }
                let replacement = imp_implementationWithBlock(block)
                if !class_addMethod(cls, added, replacement, method_getTypeEncoding(method)) {
                    method_setImplementation(method, replacement)
                }
            }
            // The native caption's ancestor recognizer can fire for a WebKit
            // tap as well. Route that exact action before any native zoom.
            let tapped = NSSelectorFromString("lyricsTapped")
            if let method = class_getInstanceMethod(cls, tapped), method_getNumberOfArguments(method) == 2 {
                typealias Original = @convention(c) (UIView, Selector) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
                let block: @convention(block) (UIView) -> Void = { view in
                    if enabled(), let host = objc_getAssociatedObject(view, &association) as? SpicyLyricsEmbeddedHost,
                       host.open() { return }
                    original(view, tapped)
                }
                let replacement = imp_implementationWithBlock(block)
                if !class_addMethod(cls, tapped, replacement, method_getTypeEncoding(method)) {
                    method_setImplementation(method, replacement)
                }
            }
            writeDebugLog("[SpicyEmbedded] installed \(surface.rawValue) in \(name)")
        }
        SpicyLyricsPreviewEntry.install(isEnabled: isEnabled)
    }

    private static func update(_ view: UIView, surface: SpicyLyricsSurface) {
        let current = objc_getAssociatedObject(view, &association) as? SpicyLyricsEmbeddedHost
        guard enabled(), view.window != nil else {
            current?.detach()
            objc_setAssociatedObject(view, &association, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        var parent = view.superview
        while let ancestor = parent {
            if objc_getAssociatedObject(ancestor, &association) is SpicyLyricsEmbeddedHost {
                current?.detach()
                objc_setAssociatedObject(view, &association, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return
            }
            parent = ancestor.superview
        }
        if let current { current.layout(); return }
        let host = SpicyLyricsEmbeddedHost(container: view, surface: surface)
        // Associate before adding children, because UIKit may lay out reentrantly.
        objc_setAssociatedObject(view, &association, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        host.attach()
    }
}

private final class SpicyLyricsEmbeddedHost {
    private final class NativeTap {
        weak var recognizer: UITapGestureRecognizer?
        let enabled: Bool
        init(_ recognizer: UITapGestureRecognizer) {
            self.recognizer = recognizer
            enabled = recognizer.isEnabled
        }
        func restore() { recognizer?.isEnabled = enabled }
    }
    private final class NativeView {
        weak var view: UIView?
        let alpha: CGFloat
        let accessibilityHidden: Bool
        let mask: CALayer?
        let suppression = CALayer()
        init(_ view: UIView) {
            self.view = view
            alpha = view.alpha
            accessibilityHidden = view.accessibilityElementsHidden
            mask = view.layer.mask
        }
        func restore() {
            view?.alpha = alpha
            view?.accessibilityElementsHidden = accessibilityHidden
            if view?.layer.mask === suppression { view?.layer.mask = mask }
        }
        func suppress() {
            view?.alpha = 0
            view?.accessibilityElementsHidden = true
            // Transparent mask remains effective when a native lyric animator
            // sets alpha back to one between layouts. No intrinsic-size change.
            view?.layer.mask = suppression
        }
    }

    private weak var container: UIView?
    private let controller = UIViewController()
    private let surface: SpicyLyricsSurface
    private var renderer: SpicyLyricsFullscreenHost?
    private var originals = [NativeView]()
    private var nativeTaps = [NativeTap]()
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
            onOpen: { [weak self] in _ = self?.open() })
        renderer = host
        if !host.attach() { fallBack(); return }
        layout()
    }

    func layout() {
        guard !updating, !failed, let container else { return }
        updating = true
        defer { updating = false }
        UIView.performWithoutAnimation {
            // A track refresh can clear the native container's children while
            // keeping the container and this associated host alive. Restore
            // our existing view before hiding the new native lyric children;
            // otherwise neither caption is visible after fullscreen closes.
            if controller.view.superview !== container {
                container.addSubview(controller.view)
            }
            // Card taps belong to the replacement. A native ancestor tap
            // must not also start Spotify's zoom behind the new window.
            if surface == .card || surface == .inline {
                var ancestor: UIView? = container
                while let view = ancestor {
                    let name = NSStringFromClass(type(of: view))
                    if view === container || (surface == .card && (name == "Lyrics_CardElementImpl.CardView"
                        || name == "_TtC22Lyrics_CardElementImpl8CardView")) {
                        for tap in (view.gestureRecognizers ?? []).compactMap({ $0 as? UITapGestureRecognizer }) {
                            if !nativeTaps.contains(where: { $0.recognizer === tap }) { nativeTaps.append(NativeTap(tap)) }
                            tap.isEnabled = false
                        }
                    }
                    ancestor = view.superview
                }
            }
            // Alpha preserves intrinsic sizes and stack layout. isHidden would
            // collapse the original layout and shrink the replacement to zero.
            for child in container.subviews where child !== controller.view {
                if !originals.contains(where: { $0.view === child }) { originals.append(NativeView(child)) }
                originals.first(where: { $0.view === child })?.suppress()
            }
            originals.removeAll { $0.view == nil }
            controller.view.frame = container.bounds
            container.bringSubviewToFront(controller.view)
        }
    }

    @discardableResult
    func open() -> Bool {
        guard !failed, let container, let owner = owningController(container) else { return false }
        SpicyLyricsFullscreenCoordinator.shared.open(from: owner)
        return true
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
        nativeTaps.forEach { $0.restore() }
        nativeTaps.removeAll()
        updating = false
    }

    deinit { renderer?.detach() }
}
