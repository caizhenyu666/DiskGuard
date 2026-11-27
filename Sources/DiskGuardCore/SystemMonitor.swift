import Foundation
import Darwin
import AppKit

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

public struct SystemSnapshot: Sendable, Equatable {
    public let timestamp: Date
    public let memory: MemoryStats
    public let cpu: CPUStats
    public let topProcesses: [ProcessMemoryInfo]

    public init(
        timestamp: Date,
        memory: MemoryStats,
        cpu: CPUStats,
        topProcesses: [ProcessMemoryInfo]
    ) {
        self.timestamp = timestamp
        self.memory = memory
        self.cpu = cpu
        self.topProcesses = topProcesses
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

public final class SystemMonitorSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previousCPUTicks: CPUTickSnapshot?

    public init() {
        self.previousCPUTicks = Self.readCPUTicks()
    }

    public func sample(includeTopProcesses: Bool, topLimit: Int = 5) -> SystemSnapshot {
        let memory = Self.readMemoryStats()
        let currentTicks = Self.readCPUTicks()

        lock.lock()
        let prev = previousCPUTicks
        if let currentTicks {
            previousCPUTicks = currentTicks
        }
        lock.unlock()

        let cpu: CPUStats
        if let currentTicks {
            cpu = CPUStats.compute(
                previous: prev,
                current: currentTicks,
                coreCount: ProcessInfo.processInfo.activeProcessorCount,
                loadAverage1m: Self.readLoadAverage1m()
            )
        } else {
            cpu = CPUStats(
                totalUsage: 0,
                userUsage: 0,
                systemUsage: 0,
                coreCount: ProcessInfo.processInfo.activeProcessorCount,
                loadAverage1m: Self.readLoadAverage1m()
            )
        }

        let processes = includeTopProcesses ? Self.readTopProcesses(limit: topLimit) : []
        return SystemSnapshot(
            timestamp: Date(),
            memory: memory,
            cpu: cpu,
            topProcesses: processes
        )
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

    public static func readTopProcesses(limit: Int = 5) -> [ProcessMemoryInfo] {
        guard limit > 0 else { return [] }

        var appNamesByPID: [Int32: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let localized = app.localizedName, !localized.isEmpty {
                appNamesByPID[app.processIdentifier] = localized
            }
        }

        let estimatedBytes = proc_listallpids(nil, 0)
        let capacity = max(256, Int(estimatedBytes / Int32(MemoryLayout<Int32>.size)) + 64)
        var pids = [Int32](repeating: 0, count: capacity)
        let actualBytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard actualBytes > 0 else { return [] }

        let pidCount = Int(actualBytes) / MemoryLayout<Int32>.size
        var results: [ProcessMemoryInfo] = []
        results.reserveCapacity(min(pidCount, 128))
        var nameBuffer = [CChar](repeating: 0, count: 256)

        for i in 0..<pidCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var rusage = rusage_info_v4()
            let rc = withUnsafeMutableBytes(of: &rusage) { raw in
                guard let base = raw.baseAddress else { return Int32(-1) }
                return proc_pid_rusage(pid, RUSAGE_INFO_V4, base.assumingMemoryBound(to: rusage_info_t?.self))
            }
            guard rc == 0, rusage.ri_phys_footprint > 0 else { continue }

            let name: String
            if let appName = appNamesByPID[pid] {
                name = appName
            } else {
                let len = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
                if len > 0 {
                    let utf8Bytes = nameBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    name = String(decoding: utf8Bytes, as: UTF8.self)
                } else {
                    name = "PID \(pid)"
                }
            }

            results.append(ProcessMemoryInfo(
                pid: pid,
                name: name,
                footprintBytes: rusage.ri_phys_footprint
            ))
        }

        results.sort { $0.footprintBytes > $1.footprintBytes }
        if results.count > limit {
            return Array(results.prefix(limit))
        }
        return results
    }
}
