import Foundation

public enum RiskTier: String, CaseIterable, Sendable, Identifiable, Hashable {
    case safe
    case caution
    case readOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .safe: return "安全缓存"
        case .caution: return "开发残留 / 需确认"
        case .readOnly: return "大体积空间洞察"
        }
    }

    public var badgeText: String {
        switch self {
        case .safe: return "安全"
        case .caution: return "需确认"
        case .readOnly: return "仅查看"
        }
    }

    public var sectionSubtitle: String {
        switch self {
        case .safe: return "可放心清理，删除后会在下次使用时自动重建"
        case .caution: return "默认不勾选，移入废纸篓前会逐条展示路径并二次确认"
        case .readOnly: return "仅做可视化占比分析，程序内永远禁止删除"
        }
    }
}

public enum CleanupMode: Sendable, Equatable, Hashable {
    case trashItem
    case trashChildren
    case readOnly
}

public struct ScanItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let categoryIcon: String
    public let tier: RiskTier
    public let cleanupMode: CleanupMode
    public let allowedRoot: URL
    public let targets: [URL]
    public let displayPathURL: URL
    public let sizeBytes: Int64
    public let lastModified: Date?
    public let lockReason: String?
    public let runningAppWarning: String?
    public let guidance: String?
    public let isWorktreeException: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        categoryIcon: String,
        tier: RiskTier,
        cleanupMode: CleanupMode,
        allowedRoot: URL,
        targets: [URL],
        displayPathURL: URL? = nil,
        sizeBytes: Int64,
        lastModified: Date? = nil,
        lockReason: String? = nil,
        runningAppWarning: String? = nil,
        guidance: String? = nil,
        isWorktreeException: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.categoryIcon = categoryIcon
        self.tier = tier
        self.cleanupMode = cleanupMode
        self.allowedRoot = allowedRoot
        self.targets = targets
        self.displayPathURL = displayPathURL ?? targets.first ?? allowedRoot
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
        self.lockReason = lockReason
        self.runningAppWarning = runningAppWarning
        self.guidance = guidance
        self.isWorktreeException = isWorktreeException
    }

    public var isSelectable: Bool {
        tier != .readOnly && cleanupMode != .readOnly && lockReason == nil && !targets.isEmpty
    }

    public var isAutoSafeSelectable: Bool {
        tier == .safe && isSelectable && runningAppWarning == nil
    }
}

public struct DirectoryEntry: Identifiable, Sendable, Hashable {
    public let id: String
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isHidden: Bool
    public var sizeBytes: Int64?
    public let modifiedDate: Date?

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        isHidden: Bool,
        sizeBytes: Int64?,
        modifiedDate: Date?
    ) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isHidden = isHidden
        self.sizeBytes = sizeBytes
        self.modifiedDate = modifiedDate
    }
}

public enum BrowserContext: Identifiable, Sendable, Hashable {
    case trash
    case folder(title: String, rootURL: URL, tier: RiskTier, allowedRoot: URL, lockReason: String?)

    public var id: String {
        switch self {
        case .trash:
            return "browser.trash"
        case .folder(_, let rootURL, _, _, _):
            return "browser.folder.\(rootURL.standardizedFileURL.path)"
        }
    }

    public var isTrash: Bool {
        if case .trash = self { return true }
        return false
    }

    public var title: String {
        switch self {
        case .trash: return "废纸篓"
        case .folder(let title, _, _, _, _): return title
        }
    }

    public var tier: RiskTier {
        switch self {
        case .trash: return .readOnly
        case .folder(_, _, let tier, _, _): return tier
        }
    }

    public var canMoveChildrenToTrash: Bool {
        switch self {
        case .trash:
            return false
        case .folder(_, _, let tier, _, let lockReason):
            return tier != .readOnly && lockReason == nil
        }
    }

    public func rootURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        switch self {
        case .trash:
            return home.appendingPathComponent(".Trash").standardizedFileURL
        case .folder(_, let rootURL, _, _, _):
            return rootURL.standardizedFileURL
        }
    }

    public func allowedRootURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        switch self {
        case .trash:
            return home.appendingPathComponent(".Trash").standardizedFileURL
        case .folder(_, _, _, let allowedRoot, _):
            return allowedRoot.standardizedFileURL
        }
    }
}

public struct VolumeStats: Sendable, Equatable {
    public let totalBytes: Int64
    public let importantAvailableBytes: Int64
    public let physicalAvailableBytes: Int64

    public init(totalBytes: Int64, importantAvailableBytes: Int64, physicalAvailableBytes: Int64) {
        self.totalBytes = totalBytes
        self.importantAvailableBytes = importantAvailableBytes
        self.physicalAvailableBytes = physicalAvailableBytes
    }

    public var usedBytes: Int64 {
        max(0, totalBytes - importantAvailableBytes)
    }

    public var purgeableBytes: Int64 {
        max(0, importantAvailableBytes - physicalAvailableBytes)
    }
}

public enum FDAStatus: Sendable, Equatable {
    case granted
    case missing(blockedPaths: [String])
}

public enum LogLevel: Sendable, Equatable {
    case info
    case success
    case warning
    case error
}

public struct LogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

public struct CleanItemReport: Sendable {
    public let itemTitle: String
    public let trashedCount: Int
    public let skippedCount: Int
    public let reclaimedBytes: Int64
    public let messages: [LogEntry]
    public let wasWorktree: Bool

    public init(
        itemTitle: String,
        trashedCount: Int,
        skippedCount: Int,
        reclaimedBytes: Int64,
        messages: [LogEntry],
        wasWorktree: Bool
    ) {
        self.itemTitle = itemTitle
        self.trashedCount = trashedCount
        self.skippedCount = skippedCount
        self.reclaimedBytes = reclaimedBytes
        self.messages = messages
        self.wasWorktree = wasWorktree
    }
}

public enum AppearanceMode: String, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public var next: AppearanceMode {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }
}

public struct ScanResult: Sendable {
    public let volumeStats: VolumeStats
    public let fdaStatus: FDAStatus
    public let items: [ScanItem]
    public let durationSeconds: TimeInterval

    public init(volumeStats: VolumeStats, fdaStatus: FDAStatus, items: [ScanItem], durationSeconds: TimeInterval) {
        self.volumeStats = volumeStats
        self.fdaStatus = fdaStatus
        self.items = items
        self.durationSeconds = durationSeconds
    }
}

public enum DiskByteFormatter {
    public static func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    public static func compactPath(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let homePath = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~/" + String(path.dropFirst(homePath.count + 1))
        }
        return path
    }
}
