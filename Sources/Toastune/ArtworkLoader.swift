import AppKit
import ImageIO
import OSAKit

/// Fetches album artwork once per track change, never during polling.
/// Spotify exposes an artwork URL (downloaded at 300 px); Music hands over the embedded image data.
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
    /// Music hands artwork over as raw data that only AppleScript can write out, so the script
    /// writes it to one reused file; reads are serialized by the script's queue.
    private let musicFile: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Toastune", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("music-artwork")
    }()
    private lazy var musicScript = PlayerScript(source: """
        tell application id "com.apple.Music"
            set theTrack to current track
            set trackID to persistent ID of theTrack
            if (count of artworks of theTrack) is 0 then return trackID
            set artData to raw data of artwork 1 of theTrack
        end tell
        set handle to open for access (POSIX file "\(musicFile.path)") with write permission
        try
            set eof handle to 0
            write artData to handle
        end try
        close access handle
        return trackID
        """, language: "AppleScript")
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
        switch track.source {
        case "com.spotify.client": return await spotifyArtwork(track)
        case "com.apple.Music": return await musicArtwork(track)
        default: return nil
        }
    }

    private func spotifyArtwork(_ track: Track) async -> NSImage? {
        guard case .success(let object) = await spotifyScript?.run(),
              object["id"] as? String == track.itemID, !Task.isCancelled,
              let string = object["url"] as? String, var url = URL(string: string) else { return nil }
        // Spotify serves the same cover at several sizes; 300 px is plenty for a 40 pt thumbnail.
        url = URL(string: string.replacingOccurrences(of: "ab67616d0000b273", with: "ab67616d00001e02")) ?? url
        guard let (bytes, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.thumbnail(from: bytes)
    }

    private func musicArtwork(_ track: Track) async -> NSImage? {
        guard case .success(let trackID) = await musicScript?.runText(), trackID == track.itemID,
              let bytes = try? Data(contentsOf: musicFile) else { return nil }
        try? FileManager.default.removeItem(at: musicFile)
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
