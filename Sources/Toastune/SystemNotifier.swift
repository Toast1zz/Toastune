import AppKit
import UserNotifications

/// Presents track changes as genuine system notification banners, drawn entirely by macOS.
/// The system decides how long a banner stays on screen. Each notification replaces the previous
/// one and is withdrawn from Notification Center shortly after, so no history of songs accumulates.
@MainActor
final class SystemNotifier: NSObject {
    private static let identifier = "now-playing"
    /// Longer than a temporary banner stays on screen, so withdrawing never cuts one short.
    private static let withdrawDelay: Double = 8
    private let center = UNUserNotificationCenter.current()
    private var withdrawTask: Task<Void, Never>?
    private var generation = 0

    override init() {
        super.init()
        center.delegate = self
    }

    /// Returns false when notifications are unavailable so the caller can fall back to the panel.
    func show(_ track: Track, showsSource: Bool, artwork: NSImage?) async -> Bool {
        guard await isAuthorized() else { return false }

        let content = UNMutableNotificationContent()
        content.title = track.title
        content.body = [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — ")
        content.threadIdentifier = track.source
        content.interruptionLevel = .active
        content.userInfo = ["source": track.source]
        // Artwork is the song's own face; the player's icon is only an opt-in fallback.
        if let artwork, let attachment = Self.imageAttachment(artwork) {
            content.attachments = [attachment]
        } else if showsSource, let attachment = Self.iconAttachment(for: track.source) {
            content.attachments = [attachment]
        }

        generation += 1
        let token = generation
        withdrawTask?.cancel()
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        do {
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
        } catch {
            NSLog("Toastune: %@", error.localizedDescription)
            return false
        }
        withdrawTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.withdrawDelay)) } catch { return }
            guard let self, self.generation == token else { return }
            self.center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        }
        return true
    }

    func hide() {
        withdrawTask?.cancel()
        generation += 1
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    private func isAuthorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert])) ?? false
        default:
            return false
        }
    }

    private static func imageAttachment(_ image: NSImage) -> UNNotificationAttachment? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        guard (try? png.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "artwork", url: file)
    }

    /// The player's icon as a thumbnail, so the banner shows where the song is playing.
    private static func iconAttachment(for bundleID: String) -> UNNotificationAttachment? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Toastune", isDirectory: true)
        let file = directory.appendingPathComponent("\(bundleID).png")
        if !FileManager.default.fileExists(atPath: file.path) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            var rect = NSRect(x: 0, y: 0, width: 256, height: 256)
            guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard (try? png.write(to: file)) != nil else { return nil }
        }
        // The system moves attachment files into its own store, so hand it a disposable copy.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: copy)
    }
}

extension SystemNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner]
    }

    /// Clicking the banner brings the player forward; it never changes playback.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let source = response.notification.request.content.userInfo["source"] as? String else { return }
        await MainActor.run {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
