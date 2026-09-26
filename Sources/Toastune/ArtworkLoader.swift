import AppKit
import ImageIO
import OSAKit

/// Fetches Spotify album artwork once per track change, never during polling.
/// Images are downsampled to thumbnail size and kept in a small in-memory cache.
@MainActor
final class ArtworkLoader {
    private static let thumbnailPixels = 160
    private static let cacheLimit = 24
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let spotifyScript = PlayerScript(source: """
        function run() {
            const item = Application("com.spotify.client").currentTrack();
            return JSON.stringify({id: item.id(), url: item.artworkUrl()});
        }
        """, language: "JavaScript")
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        return URLSession(configuration: configuration)
    }()

    func artwork(for track: Track) async -> NSImage? {
        if let cached = cache[track.identity] { return cached }
        if let running = inFlight[track.identity] { return await running.value }
        let task = Task { await fetch(track) }
        inFlight[track.identity] = task
        let image = await task.value
        inFlight[track.identity] = nil
        if let image { remember(image, for: track.identity) }
        return image
    }

    /// Stops fetches for songs that were skipped past before their artwork mattered.
    func cancel(except identity: String) {
        for (key, task) in inFlight where key != identity { task.cancel() }
    }

    /// Waits for the artwork at most `seconds`; the fetch keeps going and lands in the cache either way.
    func artwork(for track: Track, within seconds: Double) async -> NSImage? {
        if let cached = cache[track.identity] { return cached }
        let fetch = Task { await artwork(for: track) }
        let deadline = Task { try? await Task.sleep(for: .seconds(seconds)) }
        return await withCheckedContinuation { continuation in
            var resumed = false
            Task {
                let image = await fetch.value
                if !resumed { resumed = true; deadline.cancel(); continuation.resume(returning: image) }
            }
            Task {
                await deadline.value
                if !resumed { resumed = true; continuation.resume(returning: nil) }
            }
        }
    }

    private func remember(_ image: NSImage, for identity: String) {
        cache[identity] = image
        order.append(identity)
        if order.count > Self.cacheLimit { cache[order.removeFirst()] = nil }
    }

    private func fetch(_ track: Track) async -> NSImage? {
        await spotifyArtwork(track)
    }

    private func spotifyArtwork(_ track: Track) async -> NSImage? {
        guard case .success(let object) = await spotifyScript?.run(),
              object["id"] as? String == track.identity, !Task.isCancelled,
              let string = object["url"] as? String, var url = URL(string: string) else { return nil }
        // Spotify serves the same cover at several sizes; 300 px is plenty for a 40 pt thumbnail.
        url = URL(string: string.replacingOccurrences(of: "ab67616d0000b273", with: "ab67616d00001e02")) ?? url
        guard let (bytes, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.thumbnail(from: bytes)
    }

    /// Decodes straight to a small bitmap so full-size covers never sit in memory.
    private static func thumbnail(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
