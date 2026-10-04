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
