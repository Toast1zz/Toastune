// JXA uses Spotify's installed scripting dictionary; never activates the application.
function run() {
    const spotify = Application("com.spotify.client");
    const state = spotify.playerState();
    if (state === "stopped") return JSON.stringify({eligible: false, playing: false});
    const item = spotify.currentTrack();
    const id = item.id();
    // Spotify track URIs are the only supported music items. Episode URIs are podcasts.
    if (typeof id !== "string" || !id.startsWith("spotify:track:")) {
        return JSON.stringify({eligible: false, playing: state === "playing", mediaKind: "other"});
    }
    return JSON.stringify({
        eligible: true,
        mediaKind: "song",
        playing: state === "playing",
        id: id,
        title: item.name(),
        artist: item.artist(),
        album: item.album()
    });
}
