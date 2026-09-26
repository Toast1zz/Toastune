import XCTest
@testable import Toastune

final class PreferenceMigrationTests: XCTestCase {
    func testNewValuesWinAndLegacyValuesFallBackInOrder() {
        let suiteName = "ToastuneTests.PreferenceMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.setPersistentDomain(["showSongAlerts": false], forName: suiteName)
        defaults.setPersistentDomain(["showSongAlerts": true, "quietWhenPlayerFrontmost": true,
                                      "panelDuration": 9, "showTrackPanel": false], forName: "test.current")
        defaults.setPersistentDomain(["quietWhenPlayerFrontmost": false, "showTrackPanel": true,
                                      "presentationStyle": "panel"], forName: "test.oldest")

        PreferenceMigration.migrate(defaults: defaults, newDomain: suiteName,
                                    legacyDomains: ["test.current", "test.oldest"])

        XCTAssertEqual(defaults.object(forKey: "showSongAlerts") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "quietWhenPlayerFrontmost") as? Bool, true)
        XCTAssertNil(defaults.object(forKey: "panelDuration"))
        XCTAssertNil(defaults.object(forKey: "presentationStyle"))
    }

    func testCurrentToggleFallbackAndSentinelMakeMigrationOneTime() {
        let suiteName = "ToastuneTests.PreferenceMigration.\(UUID().uuidString)"
        let currentDomain = suiteName + ".current"
        let oldestDomain = suiteName + ".oldest"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.removePersistentDomain(forName: currentDomain)
            defaults.removePersistentDomain(forName: oldestDomain)
        }
        defaults.setPersistentDomain(["showTrackPanel": false], forName: currentDomain)
        defaults.setPersistentDomain(["showTrackPanel": true], forName: oldestDomain)

        PreferenceMigration.migrate(defaults: defaults, newDomain: suiteName,
                                    legacyDomains: [currentDomain, oldestDomain])
        XCTAssertEqual(defaults.object(forKey: "showSongAlerts") as? Bool, false)

        defaults.removeObject(forKey: "showSongAlerts")
        defaults.setPersistentDomain(["showTrackPanel": true], forName: currentDomain)
        PreferenceMigration.migrate(defaults: defaults, newDomain: suiteName,
                                    legacyDomains: [currentDomain, oldestDomain])
        XCTAssertNil(defaults.object(forKey: "showSongAlerts"))
    }
}
