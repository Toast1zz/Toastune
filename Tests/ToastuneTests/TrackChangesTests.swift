import XCTest
@testable import Toastune

final class TrackChangesTests: XCTestCase {
    func testFirstTrackIsSilentThenNaturalAndManualChangesAreAnnounced() {
        var changes = TrackChanges()
        XCTAssertNil(changes.accept(song("One", id: "spotify:track:1")))
        XCTAssertNil(changes.accept(song("One", id: "spotify:track:1")))
        XCTAssertEqual(changes.accept(song("Two", id: "spotify:track:2"))?.title, "Two")
        XCTAssertEqual(changes.accept(song("Three", id: "spotify:track:3"))?.title, "Three")
    }

    func testPauseResumeDoesNotDuplicateAndPausedChangeWaitsUntilPlaying() {
        var changes = TrackChanges()
        XCTAssertNil(changes.accept(song("One", id: "1")))
        XCTAssertEqual(changes.accept(song("Two", id: "2"))?.title, "Two")
        XCTAssertNil(changes.accept(song("Two", id: "2", playing: false)))
        XCTAssertNil(changes.accept(song("Two", id: "2")))
        XCTAssertNil(changes.accept(song("Three", id: "3", playing: false)))
        XCTAssertEqual(changes.accept(song("Three", id: "3"))?.title, "Three")
    }

    func testPerPlayerDedupAndIneligibleVideoDoNotInterfere() {
        var changes = TrackChanges()
        XCTAssertNil(changes.accept(song("Spotify", id: "s1")))
        XCTAssertNil(changes.accept(song("Music", id: "m1", source: "com.apple.Music")))
        XCTAssertEqual(changes.accept(song("Spotify next", id: "s2"))?.title, "Spotify next")
        XCTAssertNil(changes.accept(song("Video", id: "v1", eligible: false)))
        XCTAssertNil(changes.accept(song("Spotify next", id: "s2")))
        XCTAssertEqual(changes.accept(song("Music next", id: "m2", source: "com.apple.Music"))?.title, "Music next")
    }

    private func song(_ title: String, id: String, source: String = "com.spotify.client",
                      playing: Bool = true, eligible: Bool = true) -> [String: Any] {
        ["bundleIdentifier": source, "playing": playing, "eligible": eligible,
         "title": title, "artist": "Artist", "id": id]
    }
}
