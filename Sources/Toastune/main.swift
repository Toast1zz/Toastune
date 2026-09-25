import AppKit

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let stream = MediaStream()
    private let panel = TrackPanel()
    /// Created lazily: the notification center is only available inside an app bundle.
    private lazy var notifier = SystemNotifier()
    private let artworks = ArtworkLoader()
    private var changes = TrackChanges()
    /// The latest playing song, so the preview shows real content when something is playing.
    private var nowPlaying: Track?
    private var presentation = 0
    private var lastChange = Date.distantPast
    private var statusItem: NSStatusItem!
    private let enabledKey = "showTrackPanel"
    private let durationKey = "panelDuration"
    private let styleKey = "presentationStyle"
    private let sourceKey = "showsSourceIcon"
    private let quietKey = "quietWhenPlayerFrontmost"
    private var quietWhenPlayerFrontmost: Bool { UserDefaults.standard.bool(forKey: quietKey) }
    private var showsSource: Bool { UserDefaults.standard.bool(forKey: sourceKey) }
    private var usesSystemNotifications: Bool {
        (UserDefaults.standard.string(forKey: styleKey) ?? "system") == "system"
    }
    private var duration: Double { UserDefaults.standard.object(forKey: durationKey) as? Double ?? 3 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.toolTip = "Toastune"
        refreshMenu()
        stream.onSnapshot = { [weak self] payload in
            guard let self else { return }
            if let kind = payload["mediaKind"] as? String,
               ["video", "music video", "movie", "TV show"].contains(kind) {
                self.hideAll()
                return
            }
            if payload["playing"] as? Bool == true, let playing = Track.from(payload) {
                self.nowPlaying = playing
            }
            guard let track = self.changes.accept(payload) else { return }
            guard UserDefaults.standard.object(forKey: self.enabledKey) as? Bool ?? true else { return }
            // Someone looking at the player already sees the new song.
            if self.quietWhenPlayerFrontmost,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == track.source { return }
            self.present(track)
        }
        stream.onFailure = { [weak self] message in
            NSLog("Toastune: %@", message)
            self?.statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                                     accessibilityDescription: String(localized: "Can't read players"))
            self?.statusItem.button?.toolTip = message
        }
        stream.onRecovery = { [weak self] in
            self?.statusItem.button?.image = StatusIcon.make()
            self?.statusItem.button?.toolTip = "Toastune"
        }
        stream.start()
    }

    func applicationWillTerminate(_ notification: Notification) { stream.stop() }

    private func refreshMenu() {
        let menu = statusItem.menu ?? NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        populate(menu)
        statusItem.menu = menu
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        if musicAlsoNotifies {
            // Music's own “When song changes” notification would announce every song a second time.
            let warning = NSMenuItem(title: String(localized: "Music Also Announces Songs"),
                                     action: #selector(openMusic), keyEquivalent: "")
            warning.target = self
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            if #available(macOS 14.4, *) {
                warning.subtitle = String(localized: "Each song is announced twice. Turn off “When song changes” in Music › Settings › General.")
            }
            menu.addItem(warning)
            menu.addItem(.separator())
        }
        let enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        let toggle = NSMenuItem(title: String(localized: "Show Song Alerts"), action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)
        let durationMenu = NSMenu()
        for seconds in [2.0, 3.0, 5.0] {
            let item = NSMenuItem(title: String(localized: "\(Int(seconds)) seconds"), action: #selector(setDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = (UserDefaults.standard.object(forKey: durationKey) as? Double ?? 3) == seconds ? .on : .off
            durationMenu.addItem(item)
        }
        let durationItem = NSMenuItem(title: String(localized: "Display Time"), action: nil, keyEquivalent: "")
        menu.setSubmenu(durationMenu, for: durationItem)
        // System banners stay on screen for as long as the system decides; only the panel honors this.
        durationItem.isEnabled = !usesSystemNotifications
        durationItem.toolTip = usesSystemNotifications
            ? String(localized: "System notifications stay on screen as set in System Settings › Notifications.") : nil
        menu.addItem(durationItem)
        let styleMenu = NSMenu()
        let styles = [(String(localized: "System Notification"), "system",
                       String(localized: "Drawn by macOS; follows Focus and notification settings")),
                      (String(localized: "Floating Panel"), "panel",
                       String(localized: "Larger artwork, updates in place, no permission needed"))]
        for (title, value, subtitle) in styles {
            let item = NSMenuItem(title: title, action: #selector(setStyle(_:)), keyEquivalent: "")
            if #available(macOS 14.4, *) { item.subtitle = subtitle }
            item.target = self
            item.representedObject = value
            item.state = (usesSystemNotifications ? "system" : "panel") == value ? .on : .off
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: String(localized: "Alert Style"), action: nil, keyEquivalent: "")
        menu.setSubmenu(styleMenu, for: styleItem)
        menu.addItem(styleItem)
        let source = NSMenuItem(title: String(localized: "Show Player Icon"), action: #selector(toggleSource), keyEquivalent: "")
        source.target = self
        source.state = showsSource ? .on : .off
        menu.addItem(source)
        let quiet = NSMenuItem(title: String(localized: "Quiet While Player Is in Front"),
                               action: #selector(toggleQuiet), keyEquivalent: "")
        quiet.target = self
        quiet.state = quietWhenPlayerFrontmost ? .on : .off
        menu.addItem(quiet)
        let preview = NSMenuItem(title: String(localized: "Preview Alert"), action: #selector(previewPanel), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)
        menu.addItem(.separator())
        let players = NSMenuItem(title: String(localized: "Works with Spotify and Apple Music"), action: nil, keyEquivalent: "")
        players.isEnabled = false
        menu.addItem(players)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Toastune"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func togglePanel() {
        let enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        UserDefaults.standard.set(!enabled, forKey: enabledKey)
        if enabled { hideAll() }
        refreshMenu()
    }

    @objc private func setDuration(_ sender: NSMenuItem) {
        if let duration = sender.representedObject as? Double {
            UserDefaults.standard.set(duration, forKey: durationKey)
            refreshMenu()
        }
    }

    @objc private func toggleQuiet() {
        UserDefaults.standard.set(!quietWhenPlayerFrontmost, forKey: quietKey)
        refreshMenu()
    }

    @objc private func toggleSource() {
        UserDefaults.standard.set(!showsSource, forKey: sourceKey)
        refreshMenu()
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        if let style = sender.representedObject as? String {
            hideAll()
            UserDefaults.standard.set(style, forKey: styleKey)
            refreshMenu()
        }
    }

    @objc private func previewPanel() {
        present(nowPlaying ?? Track(source: "com.apple.Music", title: "Blue in Green", artist: "Miles Davis",
                                    album: "Kind of Blue", identity: "preview"))
    }

    /// While skipping through songs, only the one the listener settles on is announced, and artwork
    /// downloads for the skipped ones stop. Artwork starts loading during the settle delay. A system
    /// notification cannot change once posted, so it waits a little longer for artwork; the panel
    /// fades late artwork in. Falls back to the floating panel when notifications are unavailable.
    private func present(_ track: Track) {
        presentation += 1
        let token = presentation
        let system = usesSystemNotifications
        artworks.cancel(except: track.identity)
        // A change soon after another means the listener is skipping: wait longer for them to settle.
        let settle = Date().timeIntervalSince(lastChange) < 2 ? 0.9 : 0.3
        lastChange = Date()
        let prefetch = Task { await artworks.artwork(for: track) }
        Task {
            try? await Task.sleep(for: .seconds(settle))
            guard token == presentation else { return prefetch.cancel() }
            let artwork = await artworks.artwork(for: track, within: system ? 0.7 : 0.3)
            guard token == presentation else { return }
            if system, await notifier.show(track, showsSource: showsSource, artwork: artwork) { return }
            guard token == presentation else { return }
            panel.show(track, duration: duration, showsSource: showsSource, artwork: artwork)
            if artwork == nil, let late = await artworks.artwork(for: track) {
                panel.setArtwork(late, for: track)
            }
        }
    }

    /// Settings saved under the previous bundle identifier carry over once.
    private func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedLegacyDefaults"),
              let legacy = UserDefaults(suiteName: "app.toastune.Toastune") else { return }
        for key in [enabledKey, durationKey, styleKey, sourceKey, quietKey] where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedLegacyDefaults")
    }

    private func hideAll() {
        panel.hide()
        if usesSystemNotifications { notifier.hide() }
    }

    /// Rebuilt on every open so the Music warning reflects the current setting.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        populate(menu)
    }

    /// Music announces songs itself unless “When song changes” is off; the setting defaults to on.
    /// Only worth mentioning while Music is running, since that is when both would fire.
    private var musicAlsoNotifies: Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return false }
        return CFPreferencesCopyAppValue("userWantsPlaybackNotifications" as CFString, "com.apple.Music" as CFString) as? Bool ?? true
    }

    @objc private func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppController()
app.delegate = delegate
app.run()
