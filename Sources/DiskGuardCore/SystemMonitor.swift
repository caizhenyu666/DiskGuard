import Foundation
import Darwin
import AppKit
import IOKit
import IOKit.ps
import SystemConfiguration

public enum MainSectionTab: String, CaseIterable, Sendable, Identifiable {
    case storage
    case memory
    case cpu
    case health

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .storage: return "存储空间"
        case .memory: return "运行内存"
        case .cpu: return "处理器 CPU"
        case .health: return "系统状态"
        }
    }

    public var icon: String {
        switch self {
        case .storage: return "internaldrive"
        case .memory: return "memorychip"
        case .cpu: return "cpu"
        case .health: return "heart.text.square"
        }
    }
}

public enum ProcessSortMetric: String, Sendable {
    case memory
    case cpu
}

public enum MemoryByteFormatter {
    public static func string(from bytes: UInt64) -> String {
        if bytes < 1_048_576 {
            if bytes == 0 { return "0 MB" }
            let mb = Double(bytes) / 1_048_576.0
            let tenths = Int((mb * 10.0).rounded())
            if tenths == 0 { return "0 MB" }
            return tenths % 10 == 0 ? "\(tenths / 10) MB" : "\(tenths / 10).\(tenths % 10) MB"
        }
        let value = Double(bytes)
        if bytes < 1_073_741_824 {
            let tenths = Int(((value / 1_048_576.0) * 10.0).rounded())
            return tenths % 10 == 0 ? "\(tenths / 10) MB" : "\(tenths / 10).\(tenths % 10) MB"
        }
        let divisor = bytes < 1_099_511_627_776 ? 1_073_741_824.0 : 1_099_511_627_776.0
        let unit = bytes < 1_099_511_627_776 ? "GB" : "TB"
        let hundredths = Int(((value / divisor) * 100.0).rounded())
        let whole = hundredths / 100
        let frac = hundredths % 100
        if frac == 0 {
            return "\(whole) \(unit)"
        }
        if frac % 10 == 0 {
            return "\(whole).\(frac / 10) \(unit)"
        }
        return frac < 10 ? "\(whole).0\(frac) \(unit)" : "\(whole).\(frac) \(unit)"
    }

    public static func compactGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 10 {
            return String(format: "%.1fG", gb)
        } else if gb >= 1 {
            return String(format: "%.2fG", gb)
        } else {
            let mb = Double(bytes) / 1_048_576.0
            return String(format: "%.0fM", max(0, mb))
        }
    }
}

public enum NetworkSpeedFormatter {
    public static func string(bytesPerSec: Double) -> String {
        let val = max(0, bytesPerSec)
        if val >= 1_048_576 {
            return String(format: "%.1f MB/s", val / 1_048_576.0)
        } else if val >= 1024 {
            return String(format: "%.0f KB/s", val / 1024.0)
        } else {
            return String(format: "%.0f B/s", val)
        }
    }

    public static func compact(bytesPerSec: Double) -> String {
        let val = max(0, bytesPerSec)
        if val >= 1_048_576 {
            return String(format: "%.1fM/s", val / 1_048_576.0)
        } else if val >= 1024 {
            return String(format: "%.0fK/s", val / 1024.0)
        } else {
            return "0K/s"
        }
    }
}

public enum UptimeFormatter {
    public static func string(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return "\(days) 天 \(hours) 小时 \(minutes) 分钟"
        } else if hours > 0 {
            return "\(hours) 小时 \(minutes) 分钟"
        } else {
            return "\(minutes) 分钟"
        }
    }
}

public enum MemoryPressure: String, Sendable, Equatable {
    case normal
    case warning
    case critical

    public var displayName: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "紧张"
        }
    }
}

public struct MemoryStats: Sendable, Equatable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedFilesBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let pressure: MemoryPressure

    public init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        appBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedFilesBytes: UInt64,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        pressure: MemoryPressure
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressure = pressure
    }

    public var freeBytes: UInt64 {
        totalBytes > usedBytes ? totalBytes - usedBytes : 0
    }

    public var usedRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }
}

public struct CPUTickSnapshot: Sendable, Equatable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public struct CPUStats: Sendable, Equatable {
    public let totalUsage: Double
    public let userUsage: Double
    public let systemUsage: Double
    public let coreCount: Int
    public let loadAverage1m: Double

    public init(
        totalUsage: Double,
        userUsage: Double,
        systemUsage: Double,
        coreCount: Int,
        loadAverage1m: Double
    ) {
        self.totalUsage = totalUsage
        self.userUsage = userUsage
        self.systemUsage = systemUsage
        self.coreCount = coreCount
        self.loadAverage1m = loadAverage1m
    }

    public static func compute(
        previous: CPUTickSnapshot?,
        current: CPUTickSnapshot,
        coreCount: Int,
        loadAverage1m: Double
    ) -> CPUStats {
        guard let previous else {
            return CPUStats(
                totalUsage: 0,
                userUsage: 0,
                systemUsage: 0,
                coreCount: coreCount,
                loadAverage1m: loadAverage1m
            )
        }

        let dUser = UInt64(current.user &- previous.user)
        let dSystem = UInt64(current.system &- previous.system)
        let dIdle = UInt64(current.idle &- previous.idle)
        let dNice = UInt64(current.nice &- previous.nice)

        let dTotal = dUser + dSystem + dIdle + dNice
        guard dTotal > 0 else {
            return CPUStats(
                totalUsage: 0,
                userUsage: 0,
                systemUsage: 0,
                coreCount: coreCount,
                loadAverage1m: loadAverage1m
            )
        }

        let totalDouble = Double(dTotal)
        let userRatio = min(1.0, max(0.0, Double(dUser + dNice) / totalDouble))
        let systemRatio = min(1.0, max(0.0, Double(dSystem) / totalDouble))
        let totalUsage = min(1.0, max(0.0, Double(dUser + dSystem + dNice) / totalDouble))

        return CPUStats(
            totalUsage: totalUsage,
            userUsage: userRatio,
            systemUsage: systemRatio,
            coreCount: coreCount,
            loadAverage1m: loadAverage1m
        )
    }
}

public struct ProcessMemoryInfo: Identifiable, Sendable, Equatable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let footprintBytes: UInt64

    public init(pid: Int32, name: String, footprintBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.footprintBytes = footprintBytes
    }
}

public struct ProcessEntry: Identifiable, Sendable, Equatable, Hashable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let executablePath: String
    public let appBundlePath: String?
    public let footprintBytes: UInt64
    public let cpuPercent: Double
    public let isProtected: Bool

    public init(
        pid: Int32,
        name: String,
        executablePath: String,
        appBundlePath: String?,
        footprintBytes: UInt64,
        cpuPercent: Double,
        isProtected: Bool
    ) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.appBundlePath = appBundlePath
        self.footprintBytes = footprintBytes
        self.cpuPercent = cpuPercent
        self.isProtected = isProtected
    }
}

public struct ProcessGroup: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let appBundlePath: String?
    public let processes: [ProcessEntry]
    public let totalFootprintBytes: UInt64
    public let totalCPUPercent: Double
    public let isProtected: Bool

    public var processCount: Int { processes.count }

    public init(
        id: String,
        displayName: String,
        appBundlePath: String?,
        processes: [ProcessEntry],
        totalFootprintBytes: UInt64,
        totalCPUPercent: Double,
        isProtected: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.appBundlePath = appBundlePath
        self.processes = processes
        self.totalFootprintBytes = totalFootprintBytes
        self.totalCPUPercent = totalCPUPercent
        self.isProtected = isProtected
    }
}

public struct NetworkStats: Sendable, Equatable {
    public let downloadBytesPerSec: Double
    public let uploadBytesPerSec: Double
    public let totalReceivedBytes: UInt64
    public let totalSentBytes: UInt64

    public init(
        downloadBytesPerSec: Double,
        uploadBytesPerSec: Double,
        totalReceivedBytes: UInt64,
        totalSentBytes: UInt64
    ) {
        self.downloadBytesPerSec = downloadBytesPerSec
        self.uploadBytesPerSec = uploadBytesPerSec
        self.totalReceivedBytes = totalReceivedBytes
        self.totalSentBytes = totalSentBytes
    }

    public static let zero = NetworkStats(
        downloadBytesPerSec: 0,
        uploadBytesPerSec: 0,
        totalReceivedBytes: 0,
        totalSentBytes: 0
    )

    public static func compute(
        previousIn: UInt64?,
        previousOut: UInt64?,
        previousTime: TimeInterval?,
        currentIn: UInt64,
        currentOut: UInt64,
        currentTime: TimeInterval
    ) -> NetworkStats {
        guard let previousIn,
              let previousOut,
              let previousTime else {
            return NetworkStats(
                downloadBytesPerSec: 0,
                uploadBytesPerSec: 0,
                totalReceivedBytes: currentIn,
                totalSentBytes: currentOut
            )
        }

        let dt = currentTime - previousTime
        guard dt > 0.05 else {
            return NetworkStats(
                downloadBytesPerSec: 0,
                uploadBytesPerSec: 0,
                totalReceivedBytes: currentIn,
                totalSentBytes: currentOut
            )
        }

        let deltaIn = currentIn >= previousIn ? (currentIn - previousIn) : 0
        let deltaOut = currentOut >= previousOut ? (currentOut - previousOut) : 0
        return NetworkStats(
            downloadBytesPerSec: Double(deltaIn) / dt,
            uploadBytesPerSec: Double(deltaOut) / dt,
            totalReceivedBytes: currentIn,
            totalSentBytes: currentOut
        )
    }
}

public enum ThermalLevel: String, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical

    public init(processThermalState: ProcessInfo.ThermalState) {
        switch processThermalState {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    public var displayName: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "微热"
        case .serious: return "偏热 · 可能降频"
        case .critical: return "过热警告"
        }
    }
}

public struct BatteryStats: Sendable, Equatable {
    public let currentPercent: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let cycleCount: Int?
    public let healthPercent: Int?

    public init(
        currentPercent: Int,
        isCharging: Bool,
        isPluggedIn: Bool,
        cycleCount: Int?,
        healthPercent: Int?
    ) {
        self.currentPercent = currentPercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
    }
}

public enum VPNConnectionKind: String, Sendable, Equatable {
    case systemVPN
    case tunTunnel
    case systemProxy
    case direct
}

public struct SystemProxyInfo: Sendable, Equatable {
    public let httpEndpoint: String?
    public let httpsEndpoint: String?
    public let socksEndpoint: String?
    public let pacURL: String?

    public init(
        httpEndpoint: String?,
        httpsEndpoint: String?,
        socksEndpoint: String?,
        pacURL: String?
    ) {
        self.httpEndpoint = httpEndpoint
        self.httpsEndpoint = httpsEndpoint
        self.socksEndpoint = socksEndpoint
        self.pacURL = pacURL
    }

    public static let disabled = SystemProxyInfo(
        httpEndpoint: nil,
        httpsEndpoint: nil,
        socksEndpoint: nil,
        pacURL: nil
    )

    public var isEnabled: Bool {
        httpEndpoint != nil || httpsEndpoint != nil || socksEndpoint != nil || pacURL != nil
    }

    public var summary: String? {
        if let httpsEndpoint { return "HTTPS \(httpsEndpoint)" }
        if let httpEndpoint { return "HTTP \(httpEndpoint)" }
        if let socksEndpoint { return "SOCKS \(socksEndpoint)" }
        if let pacURL { return "PAC \(pacURL)" }
        return nil
    }
}

public struct VPNStatus: Sendable, Equatable {
    public let kind: VPNConnectionKind
    public let isVPNActive: Bool
    public let serviceName: String?
    public let interfaceName: String?
    public let virtualIP: String?
    public let primaryInterface: String?
    public let localIP: String?
    public let proxy: SystemProxyInfo

    public init(
        kind: VPNConnectionKind,
        isVPNActive: Bool,
        serviceName: String?,
        interfaceName: String?,
        virtualIP: String?,
        primaryInterface: String?,
        localIP: String?,
        proxy: SystemProxyInfo
    ) {
        self.kind = kind
        self.isVPNActive = isVPNActive
        self.serviceName = serviceName
        self.interfaceName = interfaceName
        self.virtualIP = virtualIP
        self.primaryInterface = primaryInterface
        self.localIP = localIP
        self.proxy = proxy
    }

    public static let direct = VPNStatus(
        kind: .direct,
        isVPNActive: false,
        serviceName: nil,
        interfaceName: nil,
        virtualIP: nil,
        primaryInterface: nil,
        localIP: nil,
        proxy: .disabled
    )

    public var shortBadgeText: String? {
        switch kind {
        case .systemVPN, .tunTunnel:
            return "VPN"
        case .systemProxy:
            return "代理"
        case .direct:
            return nil
        }
    }

    public var displayStatusText: String {
        switch kind {
        case .systemVPN: return "VPN 已连接"
        case .tunTunnel: return "TUN 隧道活跃"
        case .systemProxy: return "系统代理已开启"
        case .direct: return "直连网络"
        }
    }
}

public struct MacHealthStats: Sendable, Equatable {
    public let uptimeSeconds: TimeInterval
    public let thermal: ThermalLevel
    public let network: NetworkStats
    public let battery: BatteryStats?
    public let vpn: VPNStatus

    public init(
        uptimeSeconds: TimeInterval,
        thermal: ThermalLevel,
        network: NetworkStats,
        battery: BatteryStats?,
        vpn: VPNStatus = .direct
    ) {
        self.uptimeSeconds = uptimeSeconds
        self.thermal = thermal
        self.network = network
        self.battery = battery
        self.vpn = vpn
    }

    public static let empty = MacHealthStats(
        uptimeSeconds: 0,
        thermal: .nominal,
        network: .zero,
        battery: nil,
        vpn: .direct
    )
}

public struct SystemSnapshot: Sendable, Equatable {
    public let timestamp: Date
    public let memory: MemoryStats
    public let cpu: CPUStats
    public let topProcesses: [ProcessMemoryInfo]
    public let processes: [ProcessEntry]
    public let memoryGroups: [ProcessGroup]
    public let cpuGroups: [ProcessGroup]
    public let health: MacHealthStats

    public init(
        timestamp: Date,
        memory: MemoryStats,
        cpu: CPUStats,
        topProcesses: [ProcessMemoryInfo],
        processes: [ProcessEntry] = [],
        memoryGroups: [ProcessGroup] = [],
        cpuGroups: [ProcessGroup] = [],
        health: MacHealthStats = .empty
    ) {
        self.timestamp = timestamp
        self.memory = memory
        self.cpu = cpu
        self.topProcesses = topProcesses
        self.processes = processes
        self.memoryGroups = memoryGroups
        self.cpuGroups = cpuGroups
        self.health = health
    }
}

public enum FloatingHUDStyle: String, CaseIterable, Sendable, Identifiable {
    case transparent
    case frosted

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .transparent: return "纯透明"
        case .frosted: return "半透明毛玻璃"
        }
    }
}

public enum ProcessController {
    public enum TerminateMode: Sendable, Equatable {
        case graceful
        case force

        public var actionLabel: String {
            switch self {
            case .graceful: return "退出"
            case .force: return "强制结束"
            }
        }
    }

    public struct TerminateReport: Sendable, Equatable {
        public let targetName: String
        public let signaledCount: Int
        public let skippedProtectedCount: Int
        public let errorMessage: String?

        public init(
            targetName: String,
            signaledCount: Int,
            skippedProtectedCount: Int,
            errorMessage: String?
        ) {
            self.targetName = targetName
            self.signaledCount = signaledCount
            self.skippedProtectedCount = skippedProtectedCount
            self.errorMessage = errorMessage
        }
    }

    public static func terminate(group: ProcessGroup, mode: TerminateMode) -> TerminateReport {
        if group.isProtected {
            return TerminateReport(
                targetName: group.displayName,
                signaledCount: 0,
                skippedProtectedCount: group.processCount,
                errorMessage: "「\(group.displayName)」属于系统关键进程或 DiskGuard 自身，受保护禁止关闭"
            )
        }

        let currentPID = getpid()
        var signaled = 0
        var skipped = 0
        var lastError: String?

        for proc in group.processes {
            if proc.isProtected || proc.pid <= 1 || proc.pid == currentPID {
                skipped += 1
                continue
            }
            if signalProcess(pid: proc.pid, mode: mode, errorOut: &lastError) {
                signaled += 1
            } else {
                skipped += 1
            }
        }

        return TerminateReport(
            targetName: group.displayName,
            signaledCount: signaled,
            skippedProtectedCount: skipped,
            errorMessage: signaled == 0 ? (lastError ?? "未能结束进程，可能已退出或权限不足") : nil
        )
    }

    public static func terminate(process: ProcessEntry, mode: TerminateMode) -> TerminateReport {
        if process.isProtected || process.pid <= 1 || process.pid == getpid() {
            return TerminateReport(
                targetName: process.name,
                signaledCount: 0,
                skippedProtectedCount: 1,
                errorMessage: "「\(process.name)」受系统保护，禁止关闭"
            )
        }

        var lastError: String?
        let ok = signalProcess(pid: process.pid, mode: mode, errorOut: &lastError)
        return TerminateReport(
            targetName: process.name,
            signaledCount: ok ? 1 : 0,
            skippedProtectedCount: ok ? 0 : 1,
            errorMessage: ok ? nil : (lastError ?? "未能结束进程，可能已退出或权限不足")
        )
    }

    private static func signalProcess(pid: Int32, mode: TerminateMode, errorOut: inout String?) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            let requested = (mode == .graceful) ? app.terminate() : app.forceTerminate()
            if requested {
                return true
            }
        }

        let sig: Int32 = (mode == .graceful) ? SIGTERM : SIGKILL
        if Darwin.kill(pid, sig) == 0 {
            return true
        }
        let err = errno
        if err == ESRCH {
            return true
        }
        errorOut = String(cString: strerror(err))
        return false
    }
}

public final class SystemMonitorSampler: @unchecked Sendable {
    private struct CachedPIDInfo: Sendable {
        let startAbstime: UInt64
        let name: String
        let executablePath: String
        let appBundlePath: String?
        let isProtected: Bool
    }

    private let lock = NSLock()
    private var previousCPUTicks: CPUTickSnapshot?
    private var previousProcCPUTimes: [Int32: (cpuTicks: UInt64, wallTicks: UInt64)] = [:]
    private var pidMetadataCache: [Int32: CachedPIDInfo] = [:]
    private var previousNetwork: (rx: UInt64, tx: UInt64, time: TimeInterval)?

    private static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "windowserver", "loginwindow", "finder", "dock",
        "systemuiserver", "controlcenter", "windowmanager", "notificationcenter",
        "spotlight", "diskguard", "mds", "mds_stores", "coreaudiod", "bluetoothd",
        "airportd", "distnoted", "cfprefsd", "trustd", "securityd", "usereventagent",
        "syslogd", "notifyd", "powerd", "thermald", "runningboardd", "backboardd"
    ]

    private static let protectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.windowmanager",
        "com.apple.notificationcenterui",
        "com.apple.spotlight",
        "com.local.diskguard"
    ]

    public init() {
        self.previousCPUTicks = Self.readCPUTicks()
        let net = Self.readNetworkTotals()
        self.previousNetwork = (net.rx, net.tx, ProcessInfo.processInfo.systemUptime)
    }

    public func sample(includeTopProcesses: Bool, topLimit: Int = 5) -> SystemSnapshot {
        let now = Date()
        let wallNow = ProcessInfo.processInfo.systemUptime
        let memory = Self.readMemoryStats()
        let currentTicks = Self.readCPUTicks()
        let netTotals = Self.readNetworkTotals()
        let coreCount = ProcessInfo.processInfo.activeProcessorCount

        lock.lock()
        let prevCPU = previousCPUTicks
        if let currentTicks {
            previousCPUTicks = currentTicks
        }
        let prevNet = previousNetwork
        previousNetwork = (netTotals.rx, netTotals.tx, wallNow)
        let prevProcMap = previousProcCPUTimes
        let prevPIDCache = pidMetadataCache
        lock.unlock()

        let cpu: CPUStats
        if let currentTicks {
            cpu = CPUStats.compute(
                previous: prevCPU,
                current: currentTicks,
                coreCount: coreCount,
                loadAverage1m: Self.readLoadAverage1m()
            )
        } else {
            cpu = CPUStats(
                totalUsage: 0,
                userUsage: 0,
                systemUsage: 0,
                coreCount: coreCount,
                loadAverage1m: Self.readLoadAverage1m()
            )
        }

        let netStats = NetworkStats.compute(
            previousIn: prevNet?.rx,
            previousOut: prevNet?.tx,
            previousTime: prevNet?.time,
            currentIn: netTotals.rx,
            currentOut: netTotals.tx,
            currentTime: wallNow
        )

        let health = MacHealthStats(
            uptimeSeconds: wallNow,
            thermal: ThermalLevel(processThermalState: ProcessInfo.processInfo.thermalState),
            network: netStats,
            battery: Self.readBatteryStats(),
            vpn: Self.readVPNStatus()
        )

        var entries: [ProcessEntry] = []
        var topProcesses: [ProcessMemoryInfo] = []
        var memoryGroups: [ProcessGroup] = []
        var cpuGroups: [ProcessGroup] = []

        if includeTopProcesses {
            let (sampledEntries, nextProcMap, nextPIDCache) = Self.readAllProcesses(
                previousCPUTimes: prevProcMap,
                cachedPIDs: prevPIDCache,
                coreCount: coreCount
            )
            lock.lock()
            previousProcCPUTimes = nextProcMap
            pidMetadataCache = nextPIDCache
            lock.unlock()

            entries = sampledEntries
            memoryGroups = Self.groupProcesses(sampledEntries, sortBy: .memory)
            cpuGroups = Self.groupProcesses(sampledEntries, sortBy: .cpu)
            topProcesses = sampledEntries
                .sorted { $0.footprintBytes > $1.footprintBytes }
                .prefix(max(0, topLimit))
                .map { ProcessMemoryInfo(pid: $0.pid, name: $0.name, footprintBytes: $0.footprintBytes) }
        }

        return SystemSnapshot(
            timestamp: now,
            memory: memory,
            cpu: cpu,
            topProcesses: topProcesses,
            processes: entries,
            memoryGroups: memoryGroups,
            cpuGroups: cpuGroups,
            health: health
        )
    }

    public static func outermostAppBundlePath(from executablePath: String) -> String? {
        guard !executablePath.isEmpty else { return nil }
        let components = URL(fileURLWithPath: executablePath).pathComponents
        for (idx, comp) in components.enumerated() {
            if comp.lowercased().hasSuffix(".app"), comp.count > 4 {
                if components.first == "/" {
                    let sub = components[1...idx].joined(separator: "/")
                    return "/" + sub
                } else {
                    return components[0...idx].joined(separator: "/")
                }
            }
        }
        return nil
    }

    public static func isProtectedProcess(
        pid: Int32,
        uid: uid_t?,
        name: String,
        bundleID: String?,
        selfPID: Int32 = getpid(),
        selfUID: uid_t = getuid()
    ) -> Bool {
        if pid <= 1 || pid == selfPID {
            return true
        }
        if let uid, uid != selfUID {
            return true
        }
        if let bundleID = bundleID?.lowercased(), protectedBundleIDs.contains(bundleID) {
            return true
        }
        let lowerName = name.lowercased()
        if protectedNames.contains(lowerName) {
            return true
        }
        return false
    }

    public static func groupProcesses(
        _ entries: [ProcessEntry],
        sortBy: ProcessSortMetric
    ) -> [ProcessGroup] {
        var buckets: [String: [ProcessEntry]] = [:]
        for entry in entries {
            let key = entry.appBundlePath ?? "proc:\(entry.name)"
            buckets[key, default: []].append(entry)
        }

        var groups: [ProcessGroup] = []
        groups.reserveCapacity(buckets.count)

        for (key, rawList) in buckets {
            let sortedChildren = rawList.sorted { lhs, rhs in
                switch sortBy {
                case .memory:
                    if lhs.footprintBytes != rhs.footprintBytes {
                        return lhs.footprintBytes > rhs.footprintBytes
                    }
                    return lhs.cpuPercent > rhs.cpuPercent
                case .cpu:
                    if abs(lhs.cpuPercent - rhs.cpuPercent) > 0.05 {
                        return lhs.cpuPercent > rhs.cpuPercent
                    }
                    return lhs.footprintBytes > rhs.footprintBytes
                }
            }

            let bundlePath = sortedChildren.first?.appBundlePath
            let displayName: String
            if let bundlePath {
                displayName = URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
            } else {
                displayName = sortedChildren.first?.name ?? key
            }

            let totalBytes = sortedChildren.reduce(UInt64(0)) { $0 + $1.footprintBytes }
            let totalCPU = sortedChildren.reduce(0.0) { $0 + $1.cpuPercent }
            let isProtected = sortedChildren.contains(where: \.isProtected)

            groups.append(ProcessGroup(
                id: key,
                displayName: displayName,
                appBundlePath: bundlePath,
                processes: sortedChildren,
                totalFootprintBytes: totalBytes,
                totalCPUPercent: totalCPU,
                isProtected: isProtected
            ))
        }

        groups.sort { lhs, rhs in
            switch sortBy {
            case .memory:
                if lhs.totalFootprintBytes != rhs.totalFootprintBytes {
                    return lhs.totalFootprintBytes > rhs.totalFootprintBytes
                }
                return lhs.totalCPUPercent > rhs.totalCPUPercent
            case .cpu:
                if abs(lhs.totalCPUPercent - rhs.totalCPUPercent) > 0.05 {
                    return lhs.totalCPUPercent > rhs.totalCPUPercent
                }
                return lhs.totalFootprintBytes > rhs.totalFootprintBytes
            }
        }

        return groups
    }

    public static func readMemoryStats() -> MemoryStats {
        let totalBytes = ProcessInfo.processInfo.physicalMemory

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageBytes = UInt64(pageSize > 0 ? pageSize : 16_384)

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        let appBytes: UInt64
        let wiredBytes: UInt64
        let compressedBytes: UInt64
        let cachedFilesBytes: UInt64
        if kr == KERN_SUCCESS {
            let internalPages = UInt64(max(0, vmStats.internal_page_count))
            let purgeablePages = UInt64(max(0, vmStats.purgeable_count))
            let appPages = internalPages > purgeablePages ? (internalPages - purgeablePages) : 0
            appBytes = appPages * pageBytes
            wiredBytes = UInt64(max(0, vmStats.wire_count)) * pageBytes
            compressedBytes = UInt64(max(0, vmStats.compressor_page_count)) * pageBytes
            let externalPages = UInt64(max(0, vmStats.external_page_count))
            cachedFilesBytes = (externalPages + purgeablePages) * pageBytes
        } else {
            appBytes = 0
            wiredBytes = 0
            compressedBytes = 0
            cachedFilesBytes = 0
        }

        let usedBytes = min(totalBytes, appBytes + wiredBytes + compressedBytes)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        let swapUsed = swapOK ? UInt64(swap.xsu_used) : 0
        let swapTotal = swapOK ? UInt64(swap.xsu_total) : 0

        let usedRatio = totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
        var kernelPressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let hasKernelPressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &kernelPressure, &pressureSize, nil, 0) == 0

        let pressure: MemoryPressure
        if hasKernelPressure && kernelPressure >= 4 {
            pressure = .critical
        } else if (hasKernelPressure && kernelPressure >= 2) || usedRatio >= 0.88 {
            pressure = usedRatio >= 0.88 ? .critical : .warning
        } else if usedRatio >= 0.75 {
            pressure = .warning
        } else {
            pressure = .normal
        }

        return MemoryStats(
            totalBytes: totalBytes,
            usedBytes: usedBytes,
            appBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedFilesBytes: cachedFilesBytes,
            swapUsedBytes: swapUsed,
            swapTotalBytes: swapTotal,
            pressure: pressure
        )
    }

    public static func readCPUTicks() -> CPUTickSnapshot? {
        var cpuLoad = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &cpuLoad) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return CPUTickSnapshot(
            user: cpuLoad.cpu_ticks.0,
            system: cpuLoad.cpu_ticks.1,
            idle: cpuLoad.cpu_ticks.2,
            nice: cpuLoad.cpu_ticks.3
        )
    }

    private static func readLoadAverage1m() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, 3)
        return count > 0 ? loads[0] : 0
    }

    private static func readNetworkTotals() -> (rx: UInt64, tx: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return (0, 0)
        }
        defer { freeifaddrs(first) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first

        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp,
               !isLoopback,
               let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               let data = current.pointee.ifa_data {
                let ifData = data.assumingMemoryBound(to: if_data.self).pointee
                totalIn &+= UInt64(ifData.ifi_ibytes)
                totalOut &+= UInt64(ifData.ifi_obytes)
            }
            ptr = current.pointee.ifa_next
        }
        return (totalIn, totalOut)
    }

    public static func parseProxySettings(_ dict: [String: Any]) -> SystemProxyInfo {
        func endpoint(enableKey: String, hostKey: String, portKey: String) -> String? {
            guard (dict[enableKey] as? NSNumber)?.intValue == 1,
                  let rawHost = dict[hostKey] as? String else {
                return nil
            }
            let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return nil }
            if let port = (dict[portKey] as? NSNumber)?.intValue, port > 0 {
                return "\(host):\(port)"
            }
            return host
        }

        let pac: String?
        if (dict["ProxyAutoConfigEnable"] as? NSNumber)?.intValue == 1,
           let rawPAC = dict["ProxyAutoConfigURLString"] as? String {
            let trimmed = rawPAC.trimmingCharacters(in: .whitespacesAndNewlines)
            pac = trimmed.isEmpty ? nil : trimmed
        } else {
            pac = nil
        }

        return SystemProxyInfo(
            httpEndpoint: endpoint(enableKey: "HTTPEnable", hostKey: "HTTPProxy", portKey: "HTTPPort"),
            httpsEndpoint: endpoint(enableKey: "HTTPSEnable", hostKey: "HTTPSProxy", portKey: "HTTPSPort"),
            socksEndpoint: endpoint(enableKey: "SOCKSEnable", hostKey: "SOCKSProxy", portKey: "SOCKSPort"),
            pacURL: pac
        )
    }

    public static func isUsableNonLinkLocalIPv4(_ ip: String) -> Bool {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("127.") || trimmed.hasPrefix("169.254.") || trimmed.hasPrefix("0.") {
            return false
        }
        return true
    }

    public static func isVPNInterfaceName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let prefixes = ["utun", "ppp", "ipsec", "wg", "tun", "tap", "gpd", "feth"]
        return prefixes.contains { lower.hasPrefix($0) }
    }

    public static func classifyVPNStatus(
        primaryInterface: String?,
        activeIPv4ByInterface: [String: String],
        connectedSystemVPN: (serviceName: String, interfaceName: String?, virtualIP: String?)?,
        proxy: SystemProxyInfo
    ) -> VPNStatus {
        let localIP: String? = {
            if let primaryInterface,
               !isVPNInterfaceName(primaryInterface),
               let ip = activeIPv4ByInterface[primaryInterface],
               isUsableNonLinkLocalIPv4(ip) {
                return ip
            }
            let candidate = activeIPv4ByInterface.keys
                .filter { $0.lowercased().hasPrefix("en") && isUsableNonLinkLocalIPv4(activeIPv4ByInterface[$0] ?? "") }
                .sorted()
                .first
            if let candidate {
                return activeIPv4ByInterface[candidate]
            }
            let fallback = activeIPv4ByInterface.keys
                .filter { !isVPNInterfaceName($0) && isUsableNonLinkLocalIPv4(activeIPv4ByInterface[$0] ?? "") }
                .sorted()
                .first
            return fallback.flatMap { activeIPv4ByInterface[$0] }
        }()

        if let vpn = connectedSystemVPN {
            let resolvedIP = vpn.virtualIP
                ?? vpn.interfaceName.flatMap { activeIPv4ByInterface[$0] }
            return VPNStatus(
                kind: .systemVPN,
                isVPNActive: true,
                serviceName: vpn.serviceName,
                interfaceName: vpn.interfaceName,
                virtualIP: resolvedIP,
                primaryInterface: primaryInterface,
                localIP: localIP,
                proxy: proxy
            )
        }

        let vpnInterfaces = activeIPv4ByInterface.keys
            .filter { name in
                isVPNInterfaceName(name) && isUsableNonLinkLocalIPv4(activeIPv4ByInterface[name] ?? "")
            }
            .sorted()

        let activeTUN: String? = {
            if let primaryInterface, vpnInterfaces.contains(primaryInterface) {
                return primaryInterface
            }
            return vpnInterfaces.first
        }()

        if let activeTUN {
            return VPNStatus(
                kind: .tunTunnel,
                isVPNActive: true,
                serviceName: nil,
                interfaceName: activeTUN,
                virtualIP: activeIPv4ByInterface[activeTUN],
                primaryInterface: primaryInterface,
                localIP: localIP,
                proxy: proxy
            )
        }

        if proxy.isEnabled {
            return VPNStatus(
                kind: .systemProxy,
                isVPNActive: false,
                serviceName: nil,
                interfaceName: nil,
                virtualIP: nil,
                primaryInterface: primaryInterface,
                localIP: localIP,
                proxy: proxy
            )
        }

        return VPNStatus(
            kind: .direct,
            isVPNActive: false,
            serviceName: nil,
            interfaceName: nil,
            virtualIP: nil,
            primaryInterface: primaryInterface,
            localIP: localIP,
            proxy: proxy
        )
    }

    public static func readVPNStatus() -> VPNStatus {
        let proxyDict = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        let proxy = parseProxySettings(proxyDict)
        let activeIPv4 = readActiveIPv4ByInterface()

        guard let store = SCDynamicStoreCreate(nil, "DiskGuard" as CFString, nil, nil) else {
            return classifyVPNStatus(
                primaryInterface: nil,
                activeIPv4ByInterface: activeIPv4,
                connectedSystemVPN: nil,
                proxy: proxy
            )
        }

        let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primaryInterface = globalIPv4?["PrimaryInterface"] as? String

        let serviceKeys = (SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/(PPP|IPSec|VPN|IPv4)" as CFString) as? [String]) ?? []
        var groupedSuffixes: [String: Set<String>] = [:]
        for key in serviceKeys {
            let parts = key.split(separator: "/")
            guard parts.count >= 5 else { continue }
            let serviceID = String(parts[3])
            let suffix = String(parts[4])
            groupedSuffixes[serviceID, default: []].insert(suffix)
        }

        var connectedVPN: (serviceName: String, interfaceName: String?, virtualIP: String?)?
        let vpnTypes: Set<String> = ["PPP", "IPSec", "VPN", "com.apple.NetworkExtension"]

        for serviceID in groupedSuffixes.keys.sorted() {
            let suffixes = groupedSuffixes[serviceID] ?? []
            let setupIf = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(serviceID)/Interface" as CFString) as? [String: Any]
            let ifType = setupIf?["Type"] as? String
            let ifSubType = setupIf?["SubType"] as? String
            let hasVPNStateSubkey = suffixes.contains("PPP") || suffixes.contains("IPSec") || suffixes.contains("VPN")
            let isVPNSetup = (ifType.map { vpnTypes.contains($0) } ?? false) || (ifSubType.map { vpnTypes.contains($0) } ?? false)

            let ipv4Dict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/IPv4" as CFString) as? [String: Any]
            let stateIface = ipv4Dict?["InterfaceName"] as? String
            let stateAddresses = (ipv4Dict?["Addresses"] as? [String]) ?? []
            let stateIPv4 = stateAddresses.first(where: isUsableNonLinkLocalIPv4)
            let isVPNIface = stateIface.map(isVPNInterfaceName) ?? false

            guard hasVPNStateSubkey || isVPNSetup || isVPNIface else { continue }

            var connectedByProto = false
            var protoIface: String?
            for proto in ["VPN", "IPSec", "PPP"] where suffixes.contains(proto) {
                if let protoDict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/\(proto)" as CFString) as? [String: Any] {
                    if let pIface = protoDict["InterfaceName"] as? String {
                        protoIface = pIface
                    }
                    if let statusNum = (protoDict["Status"] as? NSNumber)?.intValue {
                        if statusNum == 8 || statusNum == 2 {
                            connectedByProto = true
                        }
                    } else if stateIPv4 != nil {
                        connectedByProto = true
                    }
                }
            }

            let resolvedIface = stateIface ?? protoIface
            let ifaceHasIP = resolvedIface.flatMap { activeIPv4[$0] }.map(isUsableNonLinkLocalIPv4) ?? false
            guard connectedByProto || stateIPv4 != nil || ifaceHasIP else { continue }

            let setupService = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(serviceID)" as CFString) as? [String: Any]
            let serviceName = (setupService?["UserDefinedName"] as? String) ?? resolvedIface ?? "VPN"
            connectedVPN = (serviceName: serviceName, interfaceName: resolvedIface, virtualIP: stateIPv4)
            break
        }

        return classifyVPNStatus(
            primaryInterface: primaryInterface,
            activeIPv4ByInterface: activeIPv4,
            connectedSystemVPN: connectedVPN,
            proxy: proxy
        )
    }

    private static func readActiveIPv4ByInterface() -> [String: String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return [:]
        }
        defer { freeifaddrs(first) }

        var result: [String: String] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))

        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let required = IFF_UP | IFF_RUNNING
            let isUpRunning = (flags & required) == required
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUpRunning,
               !isLoopback,
               let namePtr = current.pointee.ifa_name,
               let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var sinAddr = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = decodeCBuffer(buffer, maxLength: Int(INET_ADDRSTRLEN))
                    let iface = String(cString: namePtr)
                    if isUsableNonLinkLocalIPv4(ip), result[iface] == nil {
                        result[iface] = ip
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return result
    }

    private static func readBatteryStats() -> BatteryStats? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let currentCap = IORegistryEntryCreateCFProperty(service, "CurrentCapacity" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
        guard let currentCap else { return nil }

        let maxCap = IORegistryEntryCreateCFProperty(service, "AppleRawMaxCapacity" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
        let designCap = IORegistryEntryCreateCFProperty(service, "DesignCapacity" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
        let cycleCount = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
        let isCharging = IORegistryEntryCreateCFProperty(service, "IsCharging" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
        let externalConnected = IORegistryEntryCreateCFProperty(service, "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false

        let healthPercent: Int?
        if let maxCap, let designCap, designCap > 0 {
            healthPercent = min(100, max(1, Int((Double(maxCap) / Double(designCap) * 100.0).rounded())))
        } else {
            healthPercent = nil
        }

        return BatteryStats(
            currentPercent: min(100, max(0, currentCap)),
            isCharging: isCharging,
            isPluggedIn: externalConnected,
            cycleCount: cycleCount,
            healthPercent: healthPercent
        )
    }

    private static func readAllProcesses(
        previousCPUTimes: [Int32: (cpuTicks: UInt64, wallTicks: UInt64)],
        cachedPIDs: [Int32: CachedPIDInfo],
        coreCount: Int
    ) -> (
        entries: [ProcessEntry],
        cpuMap: [Int32: (cpuTicks: UInt64, wallTicks: UInt64)],
        pidCache: [Int32: CachedPIDInfo]
    ) {
        var lazyRunningInfo: [Int32: (name: String?, bundleID: String?, bundlePath: String?)]?

        let estimatedCount = proc_listallpids(nil, 0)
        let capacity = max(512, Int(estimatedCount) + 128)
        var pids = [Int32](repeating: 0, count: capacity)
        let actualCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard actualCount > 0 else { return ([], [:], [:]) }

        let pidCount = min(Int(actualCount), pids.count)
        let wallNow = mach_absolute_time()
        var entries: [ProcessEntry] = []
        entries.reserveCapacity(min(pidCount, 512))
        var nextCPUMap: [Int32: (cpuTicks: UInt64, wallTicks: UInt64)] = [:]
        nextCPUMap.reserveCapacity(pidCount)
        var nextPIDCache: [Int32: CachedPIDInfo] = [:]
        nextPIDCache.reserveCapacity(min(pidCount, 512))

        var nameBuffer = [CChar](repeating: 0, count: 256)
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        let selfPID = getpid()
        let selfUID = getuid()

        for i in 0..<pidCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var rusage = rusage_info_v4()
            let rc = withUnsafeMutableBytes(of: &rusage) { raw in
                guard let base = raw.baseAddress else { return Int32(-1) }
                return proc_pid_rusage(pid, RUSAGE_INFO_V4, base.assumingMemoryBound(to: rusage_info_t?.self))
            }
            guard rc == 0 else { continue }

            let procCPUTicks = rusage.ri_user_time &+ rusage.ri_system_time
            nextCPUMap[pid] = (procCPUTicks, wallNow)

            var cpuPercent: Double = 0
            if let prev = previousCPUTimes[pid],
               wallNow > prev.wallTicks,
               procCPUTicks >= prev.cpuTicks {
                let dCPU = procCPUTicks - prev.cpuTicks
                let dWall = wallNow - prev.wallTicks
                let rawPct = (Double(dCPU) / Double(dWall)) * 100.0
                cpuPercent = min(Double(max(1, coreCount)) * 100.0, max(0, rawPct))
            }

            let footprint = rusage.ri_phys_footprint
            guard footprint > 0 || cpuPercent >= 0.1 else { continue }

            let info: CachedPIDInfo
            if let cached = cachedPIDs[pid], cached.startAbstime == rusage.ri_proc_start_abstime {
                info = cached
            } else {
                if lazyRunningInfo == nil {
                    var map: [Int32: (name: String?, bundleID: String?, bundlePath: String?)] = [:]
                    for app in NSWorkspace.shared.runningApplications {
                        map[app.processIdentifier] = (
                            app.localizedName,
                            app.bundleIdentifier,
                            app.bundleURL?.path
                        )
                    }
                    lazyRunningInfo = map
                }
                let running = lazyRunningInfo?[pid]

                let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
                let execPath = pathLen > 0 ? Self.decodeCBuffer(pathBuffer, maxLength: Int(pathLen)) : ""

                let name: String
                if let appName = running?.name, !appName.isEmpty {
                    name = appName
                } else {
                    let len = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
                    if len > 0 {
                        name = Self.decodeCBuffer(nameBuffer, maxLength: Int(len))
                    } else if !execPath.isEmpty {
                        name = URL(fileURLWithPath: execPath).lastPathComponent
                    } else {
                        name = "PID \(pid)"
                    }
                }

                let bundlePath = Self.outermostAppBundlePath(from: execPath) ?? running?.bundlePath
                let uid = readProcessUID(pid: pid)
                let isProtected = isProtectedProcess(
                    pid: pid,
                    uid: uid,
                    name: name,
                    bundleID: running?.bundleID,
                    selfPID: selfPID,
                    selfUID: selfUID
                )

                info = CachedPIDInfo(
                    startAbstime: rusage.ri_proc_start_abstime,
                    name: name,
                    executablePath: execPath,
                    appBundlePath: bundlePath,
                    isProtected: isProtected
                )
            }

            nextPIDCache[pid] = info
            entries.append(ProcessEntry(
                pid: pid,
                name: info.name,
                executablePath: info.executablePath,
                appBundlePath: info.appBundlePath,
                footprintBytes: footprint,
                cpuPercent: cpuPercent,
                isProtected: info.isProtected
            ))
        }

        return (entries, nextCPUMap, nextPIDCache)
    }

    private static func decodeCBuffer(_ buffer: [CChar], maxLength: Int) -> String {
        buffer.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return "" }
            let bound = max(0, min(maxLength, raw.count))
            return base.withMemoryRebound(to: UInt8.self, capacity: bound) { ptr in
                let bytes = UnsafeBufferPointer(start: ptr, count: bound)
                let end = bytes.firstIndex(of: 0) ?? bound
                return String(decoding: bytes[..<end], as: UTF8.self)
            }
        }
    }

    private static func readProcessUID(pid: Int32) -> uid_t? {
        var bsdInfo = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, size)
        guard rc == size else { return nil }
        return bsdInfo.pbi_uid
    }

    public static func readTopProcesses(limit: Int = 5) -> [ProcessMemoryInfo] {
        guard limit > 0 else { return [] }
        let (entries, _, _) = readAllProcesses(
            previousCPUTimes: [:],
            cachedPIDs: [:],
            coreCount: ProcessInfo.processInfo.activeProcessorCount
        )
        return entries
            .sorted { $0.footprintBytes > $1.footprintBytes }
            .prefix(limit)
            .map { ProcessMemoryInfo(pid: $0.pid, name: $0.name, footprintBytes: $0.footprintBytes) }
    }
}
