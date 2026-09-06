import UIKit

@MainActor
private func alert(in controller: UIViewController) -> UIAlertController? {
    if let alert = controller as? UIAlertController { return alert }
    if let presented = controller.presentedViewController, let alert = alert(in: presented) { return alert }
    return controller.children.compactMap { alert(in: $0) }.first
}

@MainActor
extension QAAppDelegate {
    func verifyRouteFallback(navigation: UINavigationController) async throws {
        mark("Verifying the native route's unavailable outcome")
        routeAccepted = false
        defer { routeAccepted = true }
        try tap("local_files_open", in: table(in: navigation.topViewController!.view)!)
        try await waitUntil("an unavailable route must show a manual collection path") {
            guard let notice = alert(in: navigation) else { return false }
            return notice.viewIfLoaded?.window != nil && !notice.isBeingPresented
        }
        let notice = alert(in: navigation)!
        try expect(notice.title == "Open Local Files" &&
                   notice.message == "Couldn’t open the collection automatically. In Spotify, go to Your Library → Local Files." &&
                   notice.actions.map(\.title) == ["OK"], "the native route failure needs a clear, dismissible recovery")
        try expect(openedRoutes.map(\.absoluteString) == ["spotify:local-files", "spotify:local-files"],
                   "both route outcomes must remain at the no-effect system boundary")
        try await capture("route-unavailable")
        notice.dismiss(animated: false)
        try await waitUntil("the route notice did not dismiss") { alert(in: navigation) == nil }
    }

    func verifyLayouts(returningTo original: UINavigationController) async throws {
        guard let window = window else { throw Failure(description: "missing native layout window") }
        let originalFrame = window.frame
        defer {
            window.frame = originalFrame
            // The viewport matrix replaces the window root repeatedly. Reopen
            // the normal page instead of reusing a detached navigation snapshot.
            original.setViewControllers([makeHost()], animated: false)
            window.rootViewController = original
            window.makeKeyAndVisible()
        }
        let variants: [(String, CGSize, UIUserInterfaceStyle, UIContentSizeCategory, Bool)] = [
            ("light", CGSize(width: 393, height: 852), .light, .large, false),
            ("dark", CGSize(width: 393, height: 852), .dark, .large, false),
            ("narrow", CGSize(width: 320, height: 568), .light, .large, false),
            ("landscape", CGSize(width: 844, height: 390), .dark, .large, false),
            ("large-text", CGSize(width: 320, height: 568), .dark, .accessibilityExtraExtraExtraLarge, false),
            ("rtl", CGSize(width: 393, height: 852), .light, .large, true)
        ]
        var evidence: [[String: Any]] = []
        var defaultActionFont: CGFloat = 0
        for (name, size, style, category, rtl) in variants {
            mark("Auditing native layout: " + name)
            let container = UIViewController()
            let navigation = UINavigationController(rootViewController: makeHost())
            container.addChild(navigation)
            container.view.addSubview(navigation.view)
            navigation.didMove(toParent: container)
            navigation.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                navigation.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
                navigation.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
                navigation.view.topAnchor.constraint(equalTo: container.view.topAnchor),
                navigation.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
            ])
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: style),
                UITraitCollection(preferredContentSizeCategory: category),
                UITraitCollection(accessibilityContrast: .high),
                UITraitCollection(layoutDirection: rtl ? .rightToLeft : .leftToRight)
            ])
            container.setOverrideTraitCollection(traits, forChild: navigation)
            navigation.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = container
            window.makeKeyAndVisible()
            try await waitUntil("the requested native viewport did not render") {
                guard let host = navigation.topViewController, let list = table(in: host.view) else { return false }
                list.layoutIfNeeded()
                return list.window != nil && abs(list.bounds.width - size.width) < 1 && list.numberOfSections == 3
            }
            let list = table(in: navigation.topViewController!.view)!
            try expect(list.traitCollection.preferredContentSizeCategory == category &&
                       list.traitCollection.userInterfaceStyle == style,
                       "the audit must actually use its requested text scale and theme")
            if rtl {
                try expect(list.effectiveUserInterfaceLayoutDirection == .rightToLeft,
                           "the RTL viewport must actually use right-to-left layout")
            }
            var rows: [[String: Any]] = []
            for section in 0..<list.numberOfSections {
                for row in 0..<list.numberOfRows(inSection: section) {
                    let path = IndexPath(row: row, section: section)
                    list.scrollToRow(at: path, at: .middle, animated: false)
                    try await waitUntil("a native row was not reachable by scrolling") {
                        list.layoutIfNeeded()
                        return list.cellForRow(at: path) != nil
                    }
                    let visible = list.cellForRow(at: path)!
                    visible.layoutIfNeeded()
                    try expect(visible.isAccessibilityElement && visible.accessibilityLabel == visible.textLabel?.text &&
                               visible.accessibilityValue == visible.detailTextLabel?.text,
                               "native labels and results must remain available to accessibility")
                    if section == 0 {
                        try expect(visible.bounds.height >= 44 && visible.accessibilityTraits.contains(.button) &&
                                   visible.isUserInteractionEnabled, "native actions need a usable 44-point target and button semantics")
                    }
                    if section == 0 && row == 0 {
                        let points = visible.textLabel?.font.pointSize ?? 0
                        if name == "light" { defaultActionFont = points }
                        if name == "large-text" {
                            try expect(points >= defaultActionFont * 1.5, "accessibility text size must visibly enlarge the actions")
                        }
                    }
                    var contrasts: [Double] = []
                    for label in [visible.textLabel, visible.detailTextLabel].compactMap({ $0 }) where !(label.text ?? "").isEmpty {
                        let fit = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                        let frame = label.convert(label.bounds, to: visible.contentView)
                        try expect(!label.isHidden && label.alpha >= 0.95 && visible.contentView.alpha >= 0.95 &&
                                   label.bounds.width > 0 && label.bounds.height + 2 >= fit.height &&
                                   frame.minX >= -1 && frame.maxX <= visible.contentView.bounds.width + 1 &&
                                   frame.minY >= -1 && frame.maxY <= visible.contentView.bounds.height + 1,
                                   "native text is clipped or not painted in \(name): \(label.text ?? "")")
                        let foreground = label.textColor.resolvedColor(with: list.traitCollection)
                        let surfaces = [UIColor.systemGroupedBackground, UIColor.secondarySystemGroupedBackground]
                        let minimum = try surfaces.map { try contrast(foreground, $0.resolvedColor(with: list.traitCollection)) }.min()!
                        try expect(minimum >= 4.5, "native text contrast is below 4.5:1 in " + name)
                        contrasts.append(minimum)
                    }
                    rows.append(["name": visible.accessibilityLabel ?? "", "height": visible.bounds.height,
                                 "fontPoints": visible.textLabel?.font.pointSize ?? 0, "contrast": contrasts])
                }
            }
            list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
            try await capture("layout-" + name)
            let last = IndexPath(row: list.numberOfRows(inSection: 2) - 1, section: 2)
            list.scrollToRow(at: last, at: .bottom, animated: false)
            try await capture("layout-" + name + "-results")
            evidence.append(["variant": name, "width": list.bounds.width, "height": list.bounds.height,
                             "contentSizeCategory": category.rawValue, "rtl": rtl, "rows": rows])
        }
        let json = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: documents.appendingPathComponent("local-audio-layout.json"))
    }
}

private func contrast(_ foreground: UIColor, _ background: UIColor) throws -> Double {
    func luminance(_ color: UIColor) throws -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha >= 0.99 else {
            throw Failure(description: "native contrast requires resolved opaque colors")
        }
        let linear = [red, green, blue].map { value -> Double in
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
    let first = try luminance(foreground), second = try luminance(background)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
}
