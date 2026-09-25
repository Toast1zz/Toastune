import AppKit

/// A now-playing banner with the proportions of a macOS 27 notification banner (measured side by side):
/// artwork at the leading edge, a semibold title over body text, and a trailing accessory that is
/// either the player's icon or an animated now-playing glyph, so neither side feels empty. It never
/// shows Toastune's own icon: the banner is about the song, not the app.
@MainActor
final class TrackPanel {
    private enum Metrics {
        static let width: CGFloat = 344
        static let cornerRadius: CGFloat = 22
        static let leadingPadding: CGFloat = 10
        static let trailingPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 15
        static let iconSize: CGFloat = 40
        static let iconSpacing: CGFloat = 8
        static let thumbnailSize: CGFloat = 32
        static let artworkRadius: CGFloat = 8
        static let thumbnailSpacing: CGFloat = 10
        /// Transparent margin around the banner so the hover close button can overhang its corner.
        static let margin: CGFloat = 10
        static let screenInset: CGFloat = 6
        static let closeSize: CGFloat = 20
        static let slideDistance: CGFloat = 36
    }

    private let panel: NSPanel
    private let root = BannerRootView()
    private let artwork = ArtworkView()
    private let title = NSTextField(labelWithString: "")
    private let thumbnail = NSImageView()
    private let body = NSTextField(labelWithString: "")
    private let closeButton: NSView
    private let content: NSView
    private var fallbackBackground: NSVisualEffectView?
    private var current: Track?
    private var duration: Double = 3
    private var hideTask: Task<Void, Never>?
    private var generation = 0
    private var isVisible = false

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.alphaValue = 0
        panel.contentView = root

        let (banner, material) = Self.makeMaterial(cornerRadius: Metrics.cornerRadius)
        content = material
        content.wantsLayer = true
        fallbackBackground = banner as? NSVisualEffectView
        banner.setAccessibilityElement(true)
        banner.setAccessibilityRole(.group)
        root.addSubview(banner)
        if content.superview == nil {
            // Text layered above the glass renders at plain label contrast, as in system banners;
            // inside the glass it is brightened by the glass's own foreground treatment.
            content.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
                content.topAnchor.constraint(equalTo: banner.topAnchor),
                content.bottomAnchor.constraint(equalTo: banner.bottomAnchor)
            ])
        }

        artwork.cornerRadius = Metrics.artworkRadius
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.setAccessibilityElement(false)

        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        body.font = .systemFont(ofSize: NSFont.systemFontSize)
        body.textColor = .labelColor
        body.lineBreakMode = .byTruncatingTail
        body.maximumNumberOfLines = 2
        body.cell?.truncatesLastVisibleLine = true

        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        // Let the text column absorb the free width so the accessory sits at the trailing edge.
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [artwork, text, thumbnail])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Metrics.iconSpacing
        row.setCustomSpacing(Metrics.thumbnailSpacing, after: text)
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)

        let close: NSButton
        (closeButton, close) = Self.makeCloseButton(size: Metrics.closeSize)
        closeButton.alphaValue = 0
        root.addSubview(closeButton)

        banner.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.margin),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.margin),
            banner.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.margin),
            banner.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Metrics.margin),
            banner.widthAnchor.constraint(equalToConstant: Metrics.width),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.leadingPadding),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Metrics.trailingPadding),
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.verticalPadding),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Metrics.verticalPadding),
            artwork.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            artwork.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
            thumbnail.widthAnchor.constraint(equalToConstant: Metrics.thumbnailSize),
            thumbnail.heightAnchor.constraint(equalToConstant: Metrics.thumbnailSize),
            // Centered on the banner's rounded top-leading corner, like system notification banners.
            closeButton.centerXAnchor.constraint(equalTo: banner.leadingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: banner.topAnchor, constant: 6),
            closeButton.widthAnchor.constraint(equalToConstant: Metrics.closeSize),
            closeButton.heightAnchor.constraint(equalToConstant: Metrics.closeSize)
        ])

        root.banner = banner
        root.onHover = { [weak self] in self?.hoverChanged($0) }
        root.onClick = { [weak self] in self?.openSource() }
        close.target = self
        close.action = #selector(closeClicked)
    }

    func show(_ track: Track, duration: Double, showsSource: Bool, artwork image: NSImage?) {
        // Stay out of the way of full-screen video, presentations and full-screen apps.
        guard !Self.frontmostAppCoversScreen() else { return hide() }
        if isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Swapping songs in place crossfades the contents; the glass itself stays put.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            content.layer?.add(fade, forKey: "swap")
        }
        current = track
        artwork.setImage(image, animated: false)
        self.duration = duration
        let app = Self.sourceApp(track.source)
        setAccessory(showsSource ? app.icon : nil)
        body.preferredMaxLayoutWidth = Metrics.width - Metrics.leadingPadding - Metrics.iconSize - Metrics.iconSpacing
            - Metrics.thumbnailSpacing - Metrics.thumbnailSize - Metrics.trailingPadding
        title.stringValue = track.title
        body.stringValue = [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — ")
        body.isHidden = body.stringValue.isEmpty
        root.banner?.setAccessibilityLabel([app.name, track.title, body.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
        applyAccessibilityAppearance()

        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        let target = targetFrame(for: size)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        generation += 1
        if isVisible {
            // Replace the content in place rather than stacking banners for the same kind of event.
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
        } else {
            isVisible = true
            panel.setFrame(reduceMotion ? target : target.offsetBy(dx: Metrics.slideDistance, dy: 0), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0.2 : 0.38
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().alphaValue = 1
                if !reduceMotion { panel.animator().setFrame(target, display: true) }
            }
        }
        announce()
        scheduleHide()
    }

    /// Artwork that arrives after the banner is already up fades in over the placeholder.
    func setArtwork(_ image: NSImage, for track: Track) {
        guard isVisible, current?.identity == track.identity else { return }
        artwork.setImage(image, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func hide() {
        hideTask?.cancel()
        guard isVisible else { return }
        isVisible = false
        generation += 1
        let token = generation
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.2 : 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if !reduceMotion {
                panel.animator().setFrame(panel.frame.offsetBy(dx: Metrics.slideDistance, dy: 0), display: true)
            }
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.panel.orderOut(nil)
                self.closeButton.alphaValue = 0
            }
        }
    }

    // MARK: - Behavior

    private func scheduleHide() {
        hideTask?.cancel()
        guard !root.isHovered else { return }
        let token = generation
        hideTask = Task { [weak self, duration] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, self.generation == token else { return }
            self.hide()
        }
    }

    /// Like system banners, stay put while the pointer rests on the banner and reveal the close button.
    private func hoverChanged(_ hovering: Bool) {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            closeButton.animator().alphaValue = hovering ? 1 : 0
        }
        if hovering { hideTask?.cancel() } else { scheduleHide() }
    }

    /// Clicking the banner brings the player forward; it never changes playback.
    private func openSource() {
        guard let track = current,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: track.source) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        hide()
    }

    @objc private func closeClicked() { hide() }

    private func announce() {
        guard let label = root.banner?.accessibilityLabel() else { return }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: label,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    // MARK: - Layout and appearance

    /// The player's icon, or a quietly animated now-playing glyph that balances the artwork.
    private func setAccessory(_ playerIcon: NSImage?) {
        thumbnail.removeAllSymbolEffects(animated: false)
        if let playerIcon {
            thumbnail.image = playerIcon
            thumbnail.imageScaling = .scaleProportionallyUpOrDown
            thumbnail.contentTintColor = nil
            return
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        thumbnail.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        thumbnail.imageScaling = .scaleNone
        thumbnail.contentTintColor = .secondaryLabelColor
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            thumbnail.addSymbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
        }
    }

    /// Top trailing corner of the display with the menu bar, where macOS presents notification banners.
    private func targetFrame(for size: NSSize) -> NSRect {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.maxX - size.width - Metrics.screenInset,
                      y: visible.maxY - size.height - Metrics.screenInset,
                      width: size.width, height: size.height)
    }

    /// Whether the frontmost app has a window covering the whole banner display. Window bounds and
    /// owners are readable without Screen Recording permission; window titles are not needed.
    private static func frontmostAppCoversScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let screen = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        // Window bounds use top-left origin; the primary display's frame is the same in both systems.
        let screenFrame = screen.frame
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.width >= screenFrame.width && rect.height >= screenFrame.height
                && rect.minX <= screenFrame.minX && rect.minY <= 0
        }
    }

    /// Liquid Glass adapts to Reduce Transparency and Increase Contrast by itself; the fallback material does not.
    private func applyAccessibilityAppearance() {
        guard let background = fallbackBackground else { return }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        background.state = reduceTransparency ? .inactive : .active
        background.layer?.backgroundColor = reduceTransparency ? NSColor.windowBackgroundColor.cgColor : nil
    }

    private static func makeMaterial(cornerRadius: CGFloat) -> (container: NSView, content: NSView) {
        let content = NSView()
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            // Lifts the glass to the fill of system notification banners, measured side by side.
            glass.tintColor = NSColor(white: 1, alpha: 0.35)
            glass.cornerRadius = cornerRadius
            // The caller layers the content above the glass rather than inside it.
            return (glass, content)
        }
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        return (background, content)
    }

    private static func makeCloseButton(size: CGFloat) -> (container: NSView, button: NSButton) {
        let button = FirstMouseButton()
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))?
            .withSymbolConfiguration(config)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(String(localized: "Close"))
        button.translatesAutoresizingMaskIntoConstraints = false

        let (container, content) = makeMaterial(cornerRadius: size / 2)
        content.addSubview(button)
        if content.superview == nil {
            content.frame = NSRect(x: 0, y: 0, width: size, height: size)
            content.autoresizingMask = [.width, .height]
            container.addSubview(content)
        }
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            button.topAnchor.constraint(equalTo: content.topAnchor),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        return (container, button)
    }

    private static func sourceApp(_ bundleID: String) -> (name: String, icon: NSImage) {
        let fallbackName = bundleID == "com.apple.Music" ? "Music" : "Spotify"
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (fallbackName, NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) ?? NSImage())
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return (name.replacingOccurrences(of: ".app", with: ""), NSWorkspace.shared.icon(forFile: url.path))
    }
}

/// Root of the banner window: tracks hover over the banner and turns a click on it into an action.
/// The transparent margin stays click-through because the window only receives events on opaque pixels.
private final class BannerRootView: NSView {
    weak var banner: NSView?
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: banner?.frame.insetBy(dx: -8, dy: -8) ?? bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if banner?.frame.contains(point) == true { onClick?() }
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        onHover?(hovered)
    }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Album artwork in a rounded square. Without artwork it shows a note on a soft fill, as Music does.
private final class ArtworkView: NSView {
    var cornerRadius: CGFloat = 8 { didSet { needsDisplay = true } }
    private let glyph = NSImageView()
    private let imageLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        glyph.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        glyph.contentTintColor = .tertiaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: NSImage?, animated: Bool) {
        if imageLayer.superlayer == nil { layer?.addSublayer(imageLayer) }
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            imageLayer.add(fade, forKey: "contents")
        }
        imageLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        glyph.isHidden = image != nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        imageLayer.frame = bounds
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }
}
