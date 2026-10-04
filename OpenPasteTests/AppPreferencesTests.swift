import Foundation
import Testing
@testable import OpenPaste

@MainActor
struct AppPreferencesTests {
    @Test
    func importsLegacyRetentionPreferenceAndPersistsIt() throws {
        let suiteName = "OpenPasteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(ClipboardRetentionPolicy.oneWeek.rawValue, forKey: "clipboard.retentionPolicy")
        let preferencesStore = UserDefaultsPreferencesStore(defaults: defaults)

        #expect(preferencesStore.preferences.retentionPolicy == .oneWeek)
        #expect(defaults.data(forKey: "app.preferences") != nil)
        #expect(defaults.string(forKey: "clipboard.retentionPolicy") == ClipboardRetentionPolicy.oneWeek.rawValue)
    }

    @Test
    func savesWindowSizeAndShortcutAcrossStoreInstances() throws {
        let suiteName = "OpenPasteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = UserDefaultsPreferencesStore(defaults: defaults)
        var preferences = firstStore.preferences
        preferences.windowDimensions = WindowDimensions(width: 1040, height: 360)
        preferences.activationShortcut = ShortcutBinding(keyCode: 8, modifierFlags: 0x0100)
        firstStore.save(preferences)

        let reopenedStore = UserDefaultsPreferencesStore(defaults: defaults)
        #expect(reopenedStore.preferences.windowDimensions == WindowDimensions(width: 1040, height: 360))
        #expect(reopenedStore.preferences.activationShortcut == ShortcutBinding(keyCode: 8, modifierFlags: 0x0100))
    }

    @Test
    func expiredTimedPauseIsClearedOnLaunch() throws {
        let suiteName = "OpenPasteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var expiredPreferences = AppPreferences.default
        expiredPreferences.capturePauseState = .pausedUntil(.now.addingTimeInterval(-60))
        defaults.set(try JSONEncoder().encode(expiredPreferences), forKey: "app.preferences")

        let reopenedStore = UserDefaultsPreferencesStore(defaults: defaults)
        #expect(reopenedStore.preferences.capturePauseState == .active)
    }

    @Test
    func preferenceUpdatesPreserveUnrelatedSettings() throws {
        let suiteName = "OpenPasteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsPreferencesStore(defaults: defaults)
        store.update {
            $0.windowDimensions = WindowDimensions(width: 1100, height: 380)
            $0.capturePauseState = .pausedUntilResumed
        }
        store.update { $0.retentionPolicy = .forever }

        let reopened = UserDefaultsPreferencesStore(defaults: defaults)
        #expect(reopened.preferences.retentionPolicy == .forever)
        #expect(reopened.preferences.windowDimensions == WindowDimensions(width: 1100, height: 380))
        #expect(reopened.preferences.capturePauseState == .pausedUntilResumed)
    }

    @Test
    func timedPauseExpiresAtItsExactBoundaryAndPersistsTheRepair() throws {
        let suiteName = "OpenPasteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expiration = Date(timeIntervalSince1970: 1_000)
        var preferences = AppPreferences.default
        preferences.capturePauseState = .pausedUntil(expiration)
        defaults.set(try JSONEncoder().encode(preferences), forKey: "app.preferences")

        #expect(UserDefaultsPreferencesStore(
            defaults: defaults, now: expiration.addingTimeInterval(-1)).preferences.capturePauseState
            == .pausedUntil(expiration))
        #expect(UserDefaultsPreferencesStore(
            defaults: defaults, now: expiration).preferences.capturePauseState == .active)
        let persisted = try JSONDecoder().decode(
            AppPreferences.self, from: try #require(defaults.data(forKey: "app.preferences")))
        #expect(persisted.capturePauseState == .active)
    }

    @Test
    func invalidPreferencePayloadFallsBackToLegacyValueAndDefaults() {
        let suiteName = "OpenPasteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("invalid".utf8), forKey: "app.preferences")
        defaults.set(ClipboardRetentionPolicy.oneYear.rawValue, forKey: "clipboard.retentionPolicy")

        let store = UserDefaultsPreferencesStore(defaults: defaults)
        #expect(store.preferences.retentionPolicy == .oneYear)
        #expect(store.preferences.windowDimensions == .default)
        #expect(store.preferences.capturePauseState == .active)
    }
}
