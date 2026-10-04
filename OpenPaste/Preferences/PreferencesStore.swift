import Foundation

@MainActor
protocol PreferencesStore: AnyObject {
    var preferences: AppPreferences { get }
    func save(_ preferences: AppPreferences)
}

extension PreferencesStore {
    func update(_ change: (inout AppPreferences) -> Void) {
        var updated = preferences
        change(&updated)
        save(updated)
    }
}

@MainActor
final class UserDefaultsPreferencesStore: PreferencesStore {
    static let shared = UserDefaultsPreferencesStore()

    private enum Keys {
        static let preferences = "app.preferences"
        static let legacyRetentionPolicy = "clipboard.retentionPolicy"
    }

    private let defaults: UserDefaults
    private(set) var preferences: AppPreferences

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        preferences = Self.restore(from: defaults, now: now)
        save(preferences)
    }

    func save(_ preferences: AppPreferences) {
        self.preferences = preferences
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Keys.preferences)
        }
        defaults.set(preferences.retentionPolicy.rawValue, forKey: Keys.legacyRetentionPolicy)
    }

    private static func restore(from defaults: UserDefaults, now: Date) -> AppPreferences {
        if let data = defaults.data(forKey: Keys.preferences),
           var restored = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            if let expirationDate = restored.capturePauseState.expirationDate,
               expirationDate <= now {
                restored.capturePauseState = .active
            }
            return restored
        }

        var initial = AppPreferences.default
        if let rawValue = defaults.string(forKey: Keys.legacyRetentionPolicy),
           let policy = ClipboardRetentionPolicy(rawValue: rawValue) {
            initial.retentionPolicy = policy
        }
        return initial
    }
}
