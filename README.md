<p align="center"><img src="Design/AppIcon-256.png" width="128" alt="Toastune icon"></p>

# Toastune

A menu bar app for macOS that shows a short alert when the song changes in Spotify.

Spotify's Mac app no longer shows song-change notifications. Toastune fills that gap with a brief system notification that includes the album artwork, stays quiet while you skip through songs, and only announces songs (not podcasts or videos).

It only displays information. It never controls playback.

Toastune presents song changes as **System Notifications**, drawn by macOS through the UserNotifications framework.

Toastune has no custom alert window; alerts use macOS's own notification presentation and focus settings.
The README image and the app bundle use Toastune's colorful app artwork. The menu bar uses a separate monochrome template glyph, which macOS tints for light and dark menu bars; it is intentionally not the app icon.

## Requirements

- macOS 14 or later.
- Spotify for Mac.
- To build: Swift 6 and Xcode. Without full Xcode the build falls back to a prebuilt `.icns` icon.

## Permissions

- **Automation** (Spotify): needed to read the current song. macOS asks the first time Toastune reads Spotify. You can change it in System Settings › Privacy & Security › Automation.
- **Notifications**: required to show song alerts. Toastune requests permission when it first tries to present an alert; if permission is denied, no alert is shown. Manage this in System Settings › Notifications.

## Menu

Toastune has no window. Click the music icon in the menu bar.

- **Show Song Alerts**: turns alerts on or off.
- **Quiet While Player Is in Front**: no alert while Spotify is the frontmost app. Off by default.
- **Preview Alert**: requests notification permission if needed, then shows the current Spotify song or a sample alert when Spotify is not playing.

Clicking an alert brings Spotify to the front.

## Behavior

- The first song after launch is not announced. Pausing and resuming do not trigger an alert.
- Only Spotify `spotify:track` items are announced. Podcasts, videos and ads are ignored.
- When you skip through several songs quickly, only the one you stop on is announced, and artwork downloads for the skipped songs are cancelled.
- A new alert replaces the previous one. System notifications are removed from Notification Center about 8 seconds after delivery, so no history builds up.

## How it works
- **Detecting changes**: Spotify posts a distributed notification (`com.spotify.client.PlaybackStateChanged`) when playback changes. Each one triggers a single read through Spotify's AppleScript dictionary, using the JavaScript for Automation script in `Sources/Toastune/Resources`. A read every 15 seconds catches anything missed. The script is compiled once and reused, and Spotify is only contacted while running.
- **Artwork**: read once per song change, never while polling. Spotify's script returns an artwork URL, and Toastune downloads the 300 px version (about 20–30 KB). Images are decoded straight to 160 px thumbnails and the last 24 are kept in memory.
- **Private APIs**: none. MediaRemote is not used.

On an idle Mac, Toastune used about 0.03 s of CPU time per 30 s and about 80 MB of memory in testing.

## Privacy

Song information stays on the Mac. The only network requests are artwork downloads from Spotify's image CDN (`i.scdn.co`). Nothing is logged or uploaded.

## Limitations

- The release build is not notarized.

## Release

Toastune v0.2.1 uses bundle identifier `app.toastune.spotify` (the previous release used `app.toastune.mac`). This identity change is intentional so macOS can discard stale notification icon state.

### Upgrade from an earlier release

On its first launch, the new identity copies only `showSongAlerts` and `quietWhenPlayerFrontmost` from the new identity if already present, otherwise from `app.toastune.mac`, then `app.toastune.Toastune`. Existing values in the new identity always win, and migration runs once; unrelated preferences are not copied.

Because macOS permissions belong to the bundle identity, approve **Automation → Spotify** and **Notifications** again after upgrading. The new app must be the copy you launch: quit the old Toastune first, replace `/Applications/Toastune.app` with the refreshed bundle, then open it. Do not keep two Toastune copies running, since macOS may register the old identity separately.

## Install

### From a release

1. Download `Toastune.zip` from [Releases](../../releases) and unzip it.
2. Move `Toastune.app` to `/Applications`.
3. Quit any running older Toastune, replace the existing `/Applications/Toastune.app`, and launch the new copy. The app is not notarized. The first time, right-click it and choose **Open**, or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Toastune.app
   ```

### From source

```sh
./scripts/build.sh
ditto .build/Toastune.app /Applications/Toastune.app
open /Applications/Toastune.app
```

`build.sh` signs ad hoc by default. With ad hoc signing, macOS may ask for the Automation and notification permissions again after every rebuild. To keep them, sign with your own identity:

```sh
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build.sh
```

## Development

```sh
swift test                     # track-change logic
./scripts/build.sh             # builds .build/Toastune.app
swift scripts/make-icon.swift  # regenerates icon assets from Design/AppIcon.png
```

| Path | Contents |
|---|---|
| `Sources/Toastune/MediaStream.swift` | Spotify broadcast observer, fallback reads, compiled script |
| `Sources/Toastune/TrackChanges.swift` | Decides which Spotify snapshots count as a song change |
| `Sources/Toastune/ArtworkLoader.swift` | Artwork fetching, downsampling and caching |
| `Sources/Toastune/SystemNotifier.swift` | System notification presentation and permission handling |
| `Sources/Toastune/main.swift` | Menu, settings and presentation timing |
| `Sources/Toastune/Resources` | Spotify script, icon, localizations (English, Simplified Chinese) |


## License

MIT. See [LICENSE](LICENSE).
