import Foundation

struct Track: Equatable {
    let source: String
    let title: String
    let artist: String
    var album: String = ""
    let identity: String

    /// The player's own identifier: a Spotify URI or a Music persistent ID.
    var itemID: String { String(identity.dropFirst(source.count + 1)) }

    /// Parses an eligible music snapshot, regardless of whether it is a change.
    static func from(_ payload: [String: Any]) -> Track? {
        guard let source = payload["bundleIdentifier"] as? String,
              source == "com.spotify.client" || source == "com.apple.Music",
              payload["eligible"] as? Bool == true,
              let title = payload["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let itemID = payload["id"] as? String,
              !itemID.isEmpty else {
            return nil
        }
        return Track(source: source, title: title, artist: payload["artist"] as? String ?? "",
                     album: payload["album"] as? String ?? "", identity: source + "|" + itemID)
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.source == rhs.source && lhs.identity == rhs.identity
    }
}

/// Consumes snapshots from the player scripts. Ineligible media never changes music state.
struct TrackChanges {
    private var lastIdentityBySource: [String: String] = [:]
    private var observedSources: Set<String> = []

    mutating func accept(_ payload: [String: Any]) -> Track? {
        guard let track = Track.from(payload) else { return nil }
        let source = track.source, identity = track.identity
        if !observedSources.contains(source) {
            observedSources.insert(source)
            lastIdentityBySource[source] = identity
            return nil
        }

        // A paused snapshot must not announce a track. It also must not replace
        // a previously playing identity: if the user changes while paused, the
        // next playing snapshot is the first observable change.
        guard payload["playing"] as? Bool == true,
              identity != lastIdentityBySource[source] else {
            return nil
        }
        lastIdentityBySource[source] = identity
        return track
    }
}
