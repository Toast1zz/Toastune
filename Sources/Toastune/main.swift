import AppKit

enum PreferenceMigration {
    private static let migratedKey = "toastunePreferencesMigratedFromLegacy"
    private static let preferenceKeys = ["showSongAlerts", "quietWhenPlayerFrontmost"]
    private static let defaultLegacyDomains = ["app.toastune.mac", "app.toastune.Toastune"]

    static func migrate(defaults: UserDefaults = .standard,
                        newDomain: String = "app.toastune.spotify",
                        legacyDomains: [String] = defaultLegacyDomains) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        let newValues = defaults.persistentDomain(forName: newDomain) ?? [:]
        let legacyValues = legacyDomains.lazy.compactMap { defaults.persistentDomain(forName: $0) }
        for key in preferenceKeys where newValues[key] == nil {
            if let value = legacyValues.lazy.compactMap({ legacyValue(for: key, in: $0) }).first {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migratedKey)
    }

    private static func legacyValue(for key: String, in domain: [String: Any]) -> Any? {
        if let value = domain[key] { return value }
        guard key == "showSongAlerts", let value = domain["showTrackPanel"] as? Bool else { return nil }
        return value
    }
}
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let stream = MediaStream()
    /// The notification center is only available inside an app bundle.
    private lazy var notifier = SystemNotifier()
    private let artworks = ArtworkLoader()
    private var changes = TrackChanges()
    /// The latest playing Spotify song, used when previewing a real track.
    private var nowPlaying: Track?
    private var presentation = 0
    private var lastChange = Date.distantPast
    private var statusItem: NSStatusItem!
    private let enabledKey = "showSongAlerts"
    private let quietKey = "quietWhenPlayerFrontmost"
    private var quietWhenPlayerFrontmost: Bool { UserDefaults.standard.bool(forKey: quietKey) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PreferenceMigration.migrate()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.toolTip = "Toastune"
        refreshMenu()
        stream.onSnapshot = { [weak self] payload in
            guard let self else { return }
            if payload["playing"] as? Bool == true {
                nowPlaying = Track.from(payload)
            } else {
                nowPlaying = nil
            }
            guard let track = self.changes.accept(payload) else { return }
            guard UserDefaults.standard.object(forKey: self.enabledKey) as? Bool ?? true else { return }
            // Someone looking at Spotify already sees the new song.
            if self.quietWhenPlayerFrontmost,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.spotify.client" { return }
            self.present(track)
        }
        stream.onFailure = { [weak self] message in
            NSLog("Toastune: %@", message)
            let failureImage = NSImage(systemSymbolName: "exclamationmark.triangle",
                                       accessibilityDescription: String(localized: "Can't read Spotify"))
            failureImage?.isTemplate = true
            self?.statusItem.button?.image = failureImage
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
        let enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        let toggle = NSMenuItem(title: String(localized: "Show Song Alerts"), action: #selector(toggleAlerts), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)
        let quiet = NSMenuItem(title: String(localized: "Quiet While Player Is in Front"),
                               action: #selector(toggleQuiet), keyEquivalent: "")
        quiet.target = self
        quiet.state = quietWhenPlayerFrontmost ? .on : .off
        menu.addItem(quiet)
        let preview = NSMenuItem(title: String(localized: "Preview Alert"), action: #selector(previewAlert), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Toastune"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleAlerts() {
        let enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        UserDefaults.standard.set(!enabled, forKey: enabledKey)
        if enabled { notifier.hide() }
        refreshMenu()
    }
    @objc private func toggleQuiet() {
        UserDefaults.standard.set(!quietWhenPlayerFrontmost, forKey: quietKey)
        refreshMenu()
    }

    @objc private func previewAlert() {
        let preview = nowPlaying ?? Track(title: "Blue in Green", artist: "Miles Davis",
                                          album: "Kind of Blue", identity: "preview")
        Task { await notifier.show(preview, artwork: nil) }
    }

    /// Skipped songs settle before their artwork is attached to one genuine macOS notification.
    private func present(_ track: Track) {
        presentation += 1
        let token = presentation
        artworks.cancel(except: track.identity)
        // A change soon after another means the listener is skipping: wait longer for them to settle.
        let settle = Date().timeIntervalSince(lastChange) < 2 ? 0.9 : 0.3
        lastChange = Date()
        let prefetch = Task { await artworks.artwork(for: track) }
        Task {
            try? await Task.sleep(for: .seconds(settle))
            guard token == presentation else { return prefetch.cancel() }
            let artwork = await artworks.artwork(for: track, within: 0.7)
            guard token == presentation else { return }
            await notifier.show(track, artwork: artwork)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        populate(menu)
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppController()
app.delegate = delegate
app.run()
