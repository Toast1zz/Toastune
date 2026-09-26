import Foundation

/// A Spotify track with a stable Spotify URI identity.
struct Track: Equatable {
    let title: String
    let artist: String
    var album: String = ""
    let identity: String

    /// Parses an eligible Spotify snapshot.
    static func from(_ payload: [String: Any]) -> Track? {
        guard payload["bundleIdentifier"] as? String == "com.spotify.client",
              payload["eligible"] as? Bool == true,
              let title = payload["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let itemID = payload["id"] as? String,
              !itemID.isEmpty else {
            return nil
        }
        return Track(title: title, artist: payload["artist"] as? String ?? "",
                     album: payload["album"] as? String ?? "", identity: itemID)
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.identity == rhs.identity
    }
}

/// Consumes Spotify snapshots. Ineligible media never changes track state.
struct TrackChanges {
    private var lastIdentity: String?
    private var hasObservedTrack = false

    mutating func accept(_ payload: [String: Any]) -> Track? {
        guard let track = Track.from(payload) else { return nil }
        let identity = track.identity
        if !hasObservedTrack {
            hasObservedTrack = true
            lastIdentity = identity
            return nil
        }

        // A paused snapshot must not announce a track. It also must not replace
        // a previously playing identity: if the user changes while paused, the
        // next playing snapshot is the first observable change.
        guard payload["playing"] as? Bool == true,
              identity != lastIdentity else {
            return nil
        }
        lastIdentity = identity
        return track
    }
}
