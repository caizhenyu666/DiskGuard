import Foundation

public struct UserPreferences: Sendable {
    public let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private enum Keys {
        static let appearanceMode = "diskguard.appearanceMode"
        static let collapsedTiers = "diskguard.collapsedTiers"
        static let activeFilter = "diskguard.activeFilter"
        static let isLogDrawerExpanded = "diskguard.isLogDrawerExpanded"
    }

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        return .standard
    }

    public var appearanceMode: AppearanceMode {
        get {
            guard let raw = defaults.string(forKey: Keys.appearanceMode),
                  let mode = AppearanceMode(rawValue: raw) else {
                return .system
            }
            return mode
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Keys.appearanceMode)
        }
    }

    public var collapsedTiers: Set<RiskTier> {
        get {
            guard let rawArray = defaults.stringArray(forKey: Keys.collapsedTiers) else {
                return []
            }
            return Set(rawArray.compactMap(RiskTier.init(rawValue:)))
        }
        nonmutating set {
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Keys.collapsedTiers)
        }
    }

    public var activeFilterRawValue: String {
        get {
            defaults.string(forKey: Keys.activeFilter) ?? "all"
        }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.activeFilter)
        }
    }

    public var isLogDrawerExpanded: Bool {
        get {
            defaults.bool(forKey: Keys.isLogDrawerExpanded)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.isLogDrawerExpanded)
        }
    }
}
