import Foundation
import CoreGraphics

public enum FloatingHUDMode: String, CaseIterable, Sendable, Identifiable, Codable {
    case pet
    case pill
    case expanded

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pet: return "桌宠"
        case .pill: return "迷你胶囊"
        case .expanded: return "完整仪表盘"
        }
    }

    public var iconName: String {
        switch self {
        case .pet: return "pawprint.fill"
        case .pill: return "capsule.portrait"
        case .expanded: return "square.grid.2x2"
        }
    }
}

public enum PetDisplaySize: String, CaseIterable, Sendable, Identifiable, Codable {
    case small
    case medium
    case large

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    public var pointSize: CGFloat {
        switch self {
        case .small: return 76
        case .medium: return 96
        case .large: return 120
        }
    }
}

public enum PetMood: String, CaseIterable, Sendable, Identifiable, Codable {
    case idle
    case happy
    case busy
    case stressed
    case sleepy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .idle: return "悠闲"
        case .happy: return "开心"
        case .busy: return "忙碌"
        case .stressed: return "紧张"
        case .sleepy: return "犯困"
        }
    }

    public var badgeSymbol: String {
        switch self {
        case .idle: return "pawprint.fill"
        case .happy: return "heart.fill"
        case .busy: return "flame.fill"
        case .stressed: return "exclamationmark.triangle.fill"
        case .sleepy: return "moon.zzz.fill"
        }
    }

    public var defaultBubbleText: String {
        switch self {
        case .idle: return "状态稳稳的，我陪着你～"
        case .happy: return "贴贴！今天也要顺顺利利～"
        case .busy: return "CPU 跑起来啦，我加把劲！"
        case .stressed: return "有点挤不过来了，注意内存或空间哦"
        case .sleepy: return "有点困了…早点休息呀"
        }
    }
}

public struct PetPackManifest: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: Int
    public let moodFiles: [String: String]

    public init(id: String, name: String, version: Int = 1, moodFiles: [String: String]) {
        self.id = id
        self.name = name
        self.version = version
        self.moodFiles = moodFiles
    }
}

public struct PetPack: Identifiable, Sendable, Equatable {
    public static let builtInWestieID = "westie"

    public let id: String
    public let name: String
    public let isBuiltIn: Bool
    public let directoryURL: URL
    public let moodFiles: [PetMood: String]

    public init(
        id: String,
        name: String,
        isBuiltIn: Bool,
        directoryURL: URL,
        moodFiles: [PetMood: String]
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.directoryURL = directoryURL
        self.moodFiles = moodFiles
    }

    public func hasDedicatedArtwork(for mood: PetMood) -> Bool {
        guard let filename = moodFiles[mood] else { return false }
        let fileURL = directoryURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func imageURL(for mood: PetMood) -> URL? {
        if let filename = moodFiles[mood] {
            let candidate = directoryURL.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if mood != .idle, let idleFilename = moodFiles[.idle] {
            let fallback = directoryURL.appendingPathComponent(idleFilename)
            if FileManager.default.fileExists(atPath: fallback.path) {
                return fallback
            }
        }
        return nil
    }
}

public struct PetMoodInput: Sendable, Equatable {
    public let cpuUsage: Double
    public let memoryUsedRatio: Double
    public let memoryPressure: MemoryPressure
    public let thermal: ThermalLevel
    public let diskAvailableBytes: Int64
    public let batteryPercent: Int?
    public let batteryIsPluggedIn: Bool
    public let localHour: Int
    public let localMinute: Int
    public let isHappyBoostActive: Bool

    public init(
        cpuUsage: Double,
        memoryUsedRatio: Double,
        memoryPressure: MemoryPressure,
        thermal: ThermalLevel,
        diskAvailableBytes: Int64,
        batteryPercent: Int?,
        batteryIsPluggedIn: Bool,
        localHour: Int,
        localMinute: Int,
        isHappyBoostActive: Bool
    ) {
        self.cpuUsage = cpuUsage
        self.memoryUsedRatio = memoryUsedRatio
        self.memoryPressure = memoryPressure
        self.thermal = thermal
        self.diskAvailableBytes = diskAvailableBytes
        self.batteryPercent = batteryPercent
        self.batteryIsPluggedIn = batteryIsPluggedIn
        self.localHour = localHour
        self.localMinute = localMinute
        self.isHappyBoostActive = isHappyBoostActive
    }
}

public enum PetMoodEvaluator {
    public static let lowDiskThresholdBytes: Int64 = 15_000_000_000

    public static func evaluateRaw(input: PetMoodInput) -> PetMood {
        if input.isHappyBoostActive {
            return .happy
        }

        let memoryStressed = input.memoryPressure == .critical
            || (input.memoryPressure == .warning && input.memoryUsedRatio >= 0.85)
        let diskStressed = input.diskAvailableBytes > 0 && input.diskAvailableBytes < lowDiskThresholdBytes
        if memoryStressed || diskStressed {
            return .stressed
        }

        if input.cpuUsage >= 0.65 || input.thermal == .serious || input.thermal == .critical {
            return .busy
        }

        let isLateNight = (input.localHour == 23 && input.localMinute >= 30)
            || input.localHour < 5
            || (input.localHour == 5 && input.localMinute < 30)
        let lowBatteryUnplugged = (input.batteryPercent.map { !input.batteryIsPluggedIn && $0 < 20 }) ?? false

        if (isLateNight && input.cpuUsage < 0.30) || lowBatteryUnplugged {
            return .sleepy
        }

        return .idle
    }

    public static func bubbleMessage(
        for mood: PetMood,
        petName: String,
        memoryPercent: Int,
        cpuPercent: Int,
        diskAvailableText: String,
        reclaimedText: String?,
        triggeredByPetting: Bool
    ) -> String {
        if let reclaimedText {
            return "\(petName)帮你扫掉了 \(reclaimedText)，好轻松！"
        }
        if triggeredByPetting {
            switch mood {
            case .idle, .happy:
                return "贴贴～ 内存 \(memoryPercent)% · CPU \(cpuPercent)%"
            case .busy:
                return "呼哧呼哧…CPU \(cpuPercent)% 正在全力干活"
            case .stressed:
                return "有点吃紧！内存 \(memoryPercent)% · 剩余 \(diskAvailableText)"
            case .sleepy:
                return "迷迷糊糊求摸摸… 电量/夜深注意休息"
            }
        }
        return mood.defaultBubbleText
    }
}

public struct PetMoodStabilizer: Sendable {
    public private(set) var currentMood: PetMood
    public private(set) var lastTransitionDate: Date
    public let minimumHoldSeconds: TimeInterval

    public init(
        initialMood: PetMood = .idle,
        lastTransitionDate: Date = .distantPast,
        minimumHoldSeconds: TimeInterval = 5.0
    ) {
        self.currentMood = initialMood
        self.lastTransitionDate = lastTransitionDate
        self.minimumHoldSeconds = minimumHoldSeconds
    }

    public mutating func update(rawMood: PetMood, now: Date) -> PetMood {
        guard rawMood != currentMood else {
            return currentMood
        }

        let immediate = (rawMood == .happy || rawMood == .stressed)
        if immediate || now.timeIntervalSince(lastTransitionDate) >= minimumHoldSeconds {
            currentMood = rawMood
            lastTransitionDate = now
        }
        return currentMood
    }
}
