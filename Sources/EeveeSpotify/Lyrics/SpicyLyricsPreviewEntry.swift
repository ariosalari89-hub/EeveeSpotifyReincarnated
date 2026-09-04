import UIKit
import ObjectiveC.runtime

/// Owns only the verified native card's expand hit target. Keeping its original
/// view underneath preserves Spotify's icon, tint, sizing, and share controls.
enum SpicyLyricsPreviewEntry {
    private final class ExpandButton: UIButton {
        var accessibilityOriginals: [UIView: Bool] = [:]
        func ownAccessibility(in container: UIView) {
            for view in container.subviews where view !== self {
                if accessibilityOriginals[view] == nil { accessibilityOriginals[view] = view.accessibilityElementsHidden }
                view.accessibilityElementsHidden = true
            }
        }
        func restoreAccessibility() {
            accessibilityOriginals.forEach { $0.key.accessibilityElementsHidden = $0.value }
            accessibilityOriginals.removeAll()
        }
    }
    private static var key: UInt8 = 0
    private static var installed = false
    static func install(isEnabled: @escaping () -> Bool) {
        guard !installed else { return }
        installed = true
        var seen = Set<ObjectIdentifier>()
        for name in ["Lyrics_CardElementImpl.CardHeaderView", "_TtC22Lyrics_CardElementImpl14CardHeaderView"] {
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
                    update(view, enabled: isEnabled())
                }
                let replacement = imp_implementationWithBlock(block)
                if !class_addMethod(cls, selector, replacement, encoding) { method_setImplementation(method, replacement) }
            }
        }
    }

    private static func update(_ header: UIView, enabled: Bool) {
        let previous = objc_getAssociatedObject(header, &key) as? ExpandButton
        guard enabled, header.window != nil else {
            previous?.restoreAccessibility()
            previous?.removeFromSuperview()
            objc_setAssociatedObject(header, &key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        // Resolve the named stored UIView field at runtime; never bake a Swift
        // instance offset from the file into a live object. Fail closed if absent.
        guard let ivar = class_getInstanceVariable(type(of: header), "$__lazy_storage_$_expandButtonContainerView"),
              let container = object_getIvar(header, ivar) as? UIView,
              container.isDescendant(of: header), container.bounds.width > 0 else { return }
        if let previous {
            if previous.superview !== container {
                previous.restoreAccessibility()
                container.addSubview(previous)
            }
            previous.frame = container.bounds
            previous.ownAccessibility(in: container)
            container.bringSubviewToFront(previous)
            return
        }
        let button = ExpandButton(type: .custom)
        button.frame = container.bounds
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        button.accessibilityLabel = "Open lyrics"
        button.accessibilityIdentifier = "spicy-preview-expand"
        button.backgroundColor = .clear
        button.addAction(UIAction { [weak header] _ in
            var responder: UIResponder? = header
            while let next = responder {
                if let owner = next as? UIViewController {
                    SpicyLyricsFullscreenCoordinator.shared.open(from: owner)
                    return
                }
                responder = next.next
            }
        }, for: .touchUpInside)
        objc_setAssociatedObject(header, &key, button, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        container.addSubview(button)
        button.ownAccessibility(in: container)
    }
}
