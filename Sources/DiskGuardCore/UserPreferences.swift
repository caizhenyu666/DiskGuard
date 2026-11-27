import Foundation
import CoreGraphics

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
        static let floatingHUDCollapsed = "diskguard.floatingHUDCollapsed"
        static let activeMainSection = "diskguard.activeMainSection"
        static let showMenuBarExtra = "diskguard.showMenuBarExtra"
        static let showMenuBarMetrics = "diskguard.showMenuBarMetrics"
        static let floatingHUDMode = "diskguard.floatingHUDMode"
        static let activePetID = "diskguard.activePetID"
        static let petDisplaySize = "diskguard.petDisplaySize"
        static let floatingHUDOriginX = "diskguard.floatingHUDOriginX"
        static let floatingHUDOriginY = "diskguard.floatingHUDOriginY"
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

    public var floatingHUDCollapsed: Bool {
        get {
            defaults.bool(forKey: Keys.floatingHUDCollapsed)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.floatingHUDCollapsed)
        }
    }

    public var activeMainSectionRawValue: String {
        get {
            defaults.string(forKey: Keys.activeMainSection) ?? "storage"
        }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.activeMainSection)
        }
    }

    public var showMenuBarExtra: Bool {
        get {
            if defaults.object(forKey: Keys.showMenuBarExtra) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showMenuBarExtra)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.showMenuBarExtra)
        }
    }

    public var showMenuBarMetrics: Bool {
        get {
            if defaults.object(forKey: Keys.showMenuBarMetrics) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showMenuBarMetrics)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.showMenuBarMetrics)
        }
    }

    public var floatingHUDMode: FloatingHUDMode {
        get {
            if let raw = defaults.string(forKey: Keys.floatingHUDMode),
               let mode = FloatingHUDMode(rawValue: raw) {
                return mode
            }
            if defaults.bool(forKey: Keys.floatingHUDCollapsed) {
                return .pill
            }
            return .pet
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Keys.floatingHUDMode)
        }
    }

    public var activePetID: String {
        get {
            let value = defaults.string(forKey: Keys.activePetID)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
            return PetPack.builtInWestieID
        }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.activePetID)
        }
    }

    public var petDisplaySize: PetDisplaySize {
        get {
            guard let raw = defaults.string(forKey: Keys.petDisplaySize),
                  let size = PetDisplaySize(rawValue: raw) else {
                return .medium
            }
            return size
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Keys.petDisplaySize)
        }
    }

    public var floatingHUDOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Keys.floatingHUDOriginX) != nil,
                  defaults.object(forKey: Keys.floatingHUDOriginY) != nil else {
                return nil
            }
            return CGPoint(
                x: defaults.double(forKey: Keys.floatingHUDOriginX),
                y: defaults.double(forKey: Keys.floatingHUDOriginY)
            )
        }
        nonmutating set {
            if let newValue {
                defaults.set(Double(newValue.x), forKey: Keys.floatingHUDOriginX)
                defaults.set(Double(newValue.y), forKey: Keys.floatingHUDOriginY)
            } else {
                defaults.removeObject(forKey: Keys.floatingHUDOriginX)
                defaults.removeObject(forKey: Keys.floatingHUDOriginY)
            }
        }
    }
}
