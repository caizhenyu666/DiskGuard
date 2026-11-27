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
        static let floatingHUDOnMinimize = "diskguard.floatingHUDOnMinimize"
        static let floatingHUDAlwaysOn = "diskguard.floatingHUDAlwaysOn"
        static let floatingHUDStyle = "diskguard.floatingHUDStyle"
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

    public var floatingHUDOnMinimize: Bool {
        get {
            if defaults.object(forKey: Keys.floatingHUDOnMinimize) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.floatingHUDOnMinimize)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.floatingHUDOnMinimize)
        }
    }

    public var floatingHUDAlwaysOn: Bool {
        get {
            defaults.bool(forKey: Keys.floatingHUDAlwaysOn)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.floatingHUDAlwaysOn)
        }
    }

    public var floatingHUDStyle: FloatingHUDStyle {
        get {
            guard let raw = defaults.string(forKey: Keys.floatingHUDStyle),
                  let style = FloatingHUDStyle(rawValue: raw) else {
                return .transparent
            }
            return style
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Keys.floatingHUDStyle)
        }
    }
}
