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

    func testUnknownSourceIsIgnoredWithoutAffectingSpotifyChanges() {
        var changes = TrackChanges()
        XCTAssertNil(changes.accept(song("Spotify", id: "s1")))
        XCTAssertNil(changes.accept(song("Other", id: "o1", bundleID: "example.player")))
        XCTAssertEqual(changes.accept(song("Spotify next", id: "s2"))?.title, "Spotify next")
    }
    private func song(_ title: String, id: String, bundleID: String = "com.spotify.client",
                      playing: Bool = true, eligible: Bool = true) -> [String: Any] {
        ["bundleIdentifier": bundleID, "playing": playing, "eligible": eligible,
         "title": title, "artist": "Artist", "id": id]
    }
}
