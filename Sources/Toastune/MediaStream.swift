import AppKit
import Foundation
import OSAKit

/// Reads the current song from Spotify and Music.
/// Both players broadcast a distributed notification whenever playback changes; each broadcast
/// triggers one immediate read of that player. A slow poll only backs up missed broadcasts,
/// so an idle Mac runs a script every few seconds at most, and compiled scripts are reused.
@MainActor
final class MediaStream {
    var onFailure: ((String) -> Void)?
    var onRecovery: (() -> Void)?
    var onSnapshot: (([String: Any]) -> Void)?

    private static let fallbackInterval: Duration = .seconds(15)
    /// Broadcasts arrive in bursts when skipping; reading once per burst is enough.
    private static let burstDelay: Duration = .milliseconds(120)
    private static let broadcasts = ["com.spotify.client.PlaybackStateChanged": "com.spotify.client",
                                     "com.apple.Music.playerInfo": "com.apple.Music"]

    private var scripts: [String: PlayerScript] = [:]
    private var reportedFailures: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var pending: [String: Task<Void, Never>] = [:]
    private var loop: Task<Void, Never>?

    func start() {
        stop()
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for (bundleID, file) in [("com.spotify.client", "spotify.js"), ("com.apple.Music", "music.js")] {
            guard let source = try? String(contentsOf: resources.appendingPathComponent(file), encoding: .utf8),
                  let script = PlayerScript(source: source, language: "JavaScript") else {
                onFailure?(String(localized: "Player scripts are missing. Run scripts/build.sh."))
                return
            }
            scripts[bundleID] = script
        }

        let center = DistributedNotificationCenter.default()
        for (name, bundleID) in Self.broadcasts {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRead(bundleID) }
            })
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                for bundleID in ["com.spotify.client", "com.apple.Music"] { await self?.read(bundleID) }
                try? await Task.sleep(for: Self.fallbackInterval)
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        pending.values.forEach { $0.cancel() }; pending = [:]
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
    }

    private func scheduleRead(_ bundleID: String) {
        pending[bundleID]?.cancel()
        pending[bundleID] = Task { [weak self] in
            do { try await Task.sleep(for: Self.burstDelay) } catch { return }
            await self?.read(bundleID)
        }
    }

    private func read(_ bundleID: String) async {
        guard let script = scripts[bundleID],
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return }
        switch await script.run() {
        case .success(var payload):
            let hadFailures = !reportedFailures.isEmpty
            reportedFailures.remove(bundleID)
            if hadFailures && reportedFailures.isEmpty { onRecovery?() }
            payload["bundleIdentifier"] = bundleID
            onSnapshot?(payload)
        case .failure(let error):
            guard !reportedFailures.contains(bundleID) else { return }
            reportedFailures.insert(bundleID)
            onFailure?(error.localizedDescription)
        }
    }
}

/// A player script compiled once and executed serially on its own queue.
final class PlayerScript: @unchecked Sendable {
    private let script: OSAScript
    private let queue = DispatchQueue(label: "app.toastune.script", qos: .userInitiated)

    init?(source: String, language name: String) {
        guard let language = OSALanguage.availableLanguages().first(where: { $0.name == name }) else { return nil }
        script = OSAScript(source: source, language: language)
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { return nil }
    }

    /// Returns the script's JSON result as a dictionary.
    func run() async -> Result<[String: Any], Error> {
        switch await runText() {
        case .success(let text):
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(ScriptError.failed(String(localized: "The player didn't respond to Toastune.")))
            }
            return .success(object)
        case .failure(let error):
            return .failure(error)
        }
    }

    func runText() async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var error: NSDictionary?
                if let text = self.script.executeAndReturnError(&error)?.stringValue {
                    continuation.resume(returning: .success(text))
                } else {
                    let code = error?[OSAScriptErrorNumberKey] as? Int ?? 0
                    let message = code == -1743
                        ? String(localized: "Toastune isn't allowed to read the player. Allow it in System Settings › Privacy & Security › Automation.")
                        : String(localized: "The player didn't respond to Toastune.")
                    continuation.resume(returning: .failure(ScriptError.failed(message)))
                }
            }
        }
    }

    enum ScriptError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}
