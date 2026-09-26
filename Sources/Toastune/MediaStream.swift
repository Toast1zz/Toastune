import AppKit
import Foundation
import OSAKit

/// Reads Spotify snapshots from playback-change broadcasts, with a slow backup poll.
/// Scripts are compiled once and reused.
///
/// Broadcast bursts are coalesced; an idle Mac only runs a script every few seconds at most.
@MainActor
final class MediaStream {
    var onFailure: ((String) -> Void)?
    var onRecovery: (() -> Void)?
    var onSnapshot: (([String: Any]) -> Void)?
    private static let fallbackInterval: Duration = .seconds(15)
    private static let burstDelay: Duration = .milliseconds(120)

    private static let broadcast = "com.spotify.client.PlaybackStateChanged"

    private var script: PlayerScript?
    private var hasReportedFailure = false
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var loop: Task<Void, Never>?

    func start() {
        stop()
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let source = try? String(contentsOf: resources.appendingPathComponent("spotify.js"), encoding: .utf8),
              let playerScript = PlayerScript(source: source, language: "JavaScript") else {
            onFailure?(String(localized: "Player scripts are missing. Run scripts/build.sh."))
            return
        }
        script = playerScript

        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name(Self.broadcast), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRead() }
        })
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.read()
                try? await Task.sleep(for: Self.fallbackInterval)
            }
        }
    }
    func stop() {
        loop?.cancel(); loop = nil
        pending?.cancel(); pending = nil
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
    }

    private func scheduleRead() {
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: Self.burstDelay) } catch { return }
            await self?.read()
        }
    }

    private func read() async {
        guard let script,
              !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return }
        switch await script.run() {
        case .success(let payload):
            if hasReportedFailure { onRecovery?() }
            hasReportedFailure = false
            onSnapshot?(payload)
        case .failure(let error):
            guard !hasReportedFailure else { return }
            hasReportedFailure = true
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
                return .failure(ScriptError.failed(String(localized: "Spotify didn't respond to Toastune.")))
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
                        ? String(localized: "Toastune isn't allowed to read Spotify. Allow it in System Settings › Privacy & Security › Automation.")
                        : String(localized: "Spotify didn't respond to Toastune.")
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
