// Music's scripting dictionary exposes media kind; only songs are eligible.
function run() {
    const music = Application("com.apple.Music");
    const state = music.playerState();
    if (state === "stopped") return JSON.stringify({eligible: false, playing: false});
    const item = music.currentTrack();
    const mediaKind = item.mediaKind();
    if (mediaKind !== "song") {
        return JSON.stringify({eligible: false, playing: state === "playing", mediaKind: mediaKind});
    }
    return JSON.stringify({
        eligible: true,
        playing: state === "playing",
        mediaKind: mediaKind,
        id: item.persistentID(),
        title: item.name(),
        artist: item.artist(),
        album: item.album()
    });
}
