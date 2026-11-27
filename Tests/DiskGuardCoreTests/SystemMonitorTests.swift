import Foundation
import Testing
@testable import DiskGuardCore

@Suite("SystemMonitor & Floating HUD Preferences Tests")
struct SystemMonitorTests {
    @Test("CPUStats.compute handles nil previous, zero delta, normal delta, and UInt32 wraparound")
    func cpuStatsComputationAndWraparound() {
        let initial = CPUStats.compute(
            previous: nil,
            current: CPUTickSnapshot(user: 100, system: 50, idle: 850, nice: 0),
            coreCount: 8,
            loadAverage1m: 1.25
        )
        #expect(initial.totalUsage == 0)
        #expect(initial.coreCount == 8)

        let zeroDelta = CPUStats.compute(
            previous: CPUTickSnapshot(user: 100, system: 50, idle: 850, nice: 0),
            current: CPUTickSnapshot(user: 100, system: 50, idle: 850, nice: 0),
            coreCount: 8,
            loadAverage1m: 1.0
        )
        #expect(zeroDelta.totalUsage == 0)

        let normal = CPUStats.compute(
            previous: CPUTickSnapshot(user: 100, system: 50, idle: 850, nice: 0),
            current: CPUTickSnapshot(user: 130, system: 60, idle: 900, nice: 10),
            coreCount: 8,
            loadAverage1m: 2.0
        )
        // dUser=30, dSystem=10, dIdle=50, dNice=10 -> dTotal=100, active=50 -> 0.50
        #expect(abs(normal.totalUsage - 0.5) < 0.0001)
        #expect(abs(normal.userUsage - 0.4) < 0.0001)
        #expect(abs(normal.systemUsage - 0.1) < 0.0001)

        // UInt32 counter wraparound: user wraps by 20, system by 10, idle by 70 -> total 100, active 30%
        let wrapped = CPUStats.compute(
            previous: CPUTickSnapshot(user: UInt32.max - 9, system: UInt32.max - 4, idle: UInt32.max - 19, nice: 10),
            current: CPUTickSnapshot(user: 10, system: 5, idle: 50, nice: 10),
            coreCount: 8,
            loadAverage1m: 0.5
        )
        #expect(abs(wrapped.totalUsage - 0.3) < 0.0001)
        #expect(abs(wrapped.userUsage - 0.2) < 0.0001)
        #expect(abs(wrapped.systemUsage - 0.1) < 0.0001)
    }

    @Test("SystemMonitorSampler reads valid physical RAM, CPU stats, and sorted top processes")
    func systemMonitorSamplerLiveSample() {
        let sampler = SystemMonitorSampler()
        let snapshot = sampler.sample(includeTopProcesses: true, topLimit: 5)

        #expect(snapshot.memory.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(snapshot.memory.usedBytes > 0)
        #expect(snapshot.memory.usedBytes <= snapshot.memory.totalBytes)
        #expect(snapshot.memory.usedRatio > 0 && snapshot.memory.usedRatio <= 1.0)
        #expect(snapshot.cpu.coreCount == ProcessInfo.processInfo.activeProcessorCount)
        #expect(snapshot.cpu.totalUsage >= 0 && snapshot.cpu.totalUsage <= 1.0)
        #expect(!snapshot.topProcesses.isEmpty)
        #expect(snapshot.topProcesses.count <= 5)

        for i in 1..<snapshot.topProcesses.count {
            #expect(snapshot.topProcesses[i - 1].footprintBytes >= snapshot.topProcesses[i].footprintBytes)
        }
    }

    @Test("UserPreferences persists floating HUD defaults and updates")
    func floatingHUDPreferencesPersistence() {
        let suite = "com.local.diskguard.hud.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let defaultsReader = UserPreferences(suiteName: suite)
        #expect(defaultsReader.floatingHUDOnMinimize == true)
        #expect(defaultsReader.floatingHUDAlwaysOn == false)
        #expect(defaultsReader.floatingHUDStyle == .transparent)

        defaultsReader.floatingHUDOnMinimize = false
        defaultsReader.floatingHUDAlwaysOn = true
        defaultsReader.floatingHUDStyle = .frosted

        let reloaded = UserPreferences(suiteName: suite)
        #expect(reloaded.floatingHUDOnMinimize == false)
        #expect(reloaded.floatingHUDAlwaysOn == true)
        #expect(reloaded.floatingHUDStyle == .frosted)

        #expect(reloaded.activeMainSectionRawValue == "storage")
        #expect(reloaded.floatingHUDCollapsed == false)
        #expect(reloaded.showMenuBarExtra == true)
        #expect(reloaded.showMenuBarMetrics == true)

        reloaded.activeMainSectionRawValue = "memory"
        reloaded.floatingHUDCollapsed = true
        reloaded.showMenuBarExtra = false
        reloaded.showMenuBarMetrics = false

        let secondReload = UserPreferences(suiteName: suite)
        #expect(secondReload.activeMainSectionRawValue == "memory")
        #expect(secondReload.floatingHUDCollapsed == true)
        #expect(secondReload.showMenuBarExtra == false)
        #expect(secondReload.showMenuBarMetrics == false)
    }

    @Test("outermostAppBundlePath extracts top-level .app for nested helper executables")
    func outermostAppBundlePathExtraction() {
        let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(SystemMonitorSampler.outermostAppBundlePath(from: chromeHelper) == "/Applications/Google Chrome.app")

        let directApp = "/Applications/Xcode.app/Contents/MacOS/Xcode"
        #expect(SystemMonitorSampler.outermostAppBundlePath(from: directApp) == "/Applications/Xcode.app")

        let cliTool = "/usr/bin/git"
        #expect(SystemMonitorSampler.outermostAppBundlePath(from: cliTool) == nil)
    }

    @Test("groupProcesses merges same-app processes, sums totals, sorts by memory/cpu, and propagates protection")
    func processGroupingAndSorting() {
        let entries = [
            ProcessEntry(pid: 101, name: "Google Chrome", executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", appBundlePath: "/Applications/Google Chrome.app", footprintBytes: 300_000_000, cpuPercent: 4.5, isProtected: false),
            ProcessEntry(pid: 102, name: "Chrome Helper", executablePath: "/Applications/Google Chrome.app/Contents/Helpers/Helper", appBundlePath: "/Applications/Google Chrome.app", footprintBytes: 500_000_000, cpuPercent: 12.5, isProtected: false),
            ProcessEntry(pid: 201, name: "python3", executablePath: "/usr/bin/python3", appBundlePath: nil, footprintBytes: 600_000_000, cpuPercent: 25.0, isProtected: false),
            ProcessEntry(pid: 301, name: "Finder", executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", appBundlePath: "/System/Library/CoreServices/Finder.app", footprintBytes: 900_000_000, cpuPercent: 1.0, isProtected: true)
        ]

        let byMemory = SystemMonitorSampler.groupProcesses(entries, sortBy: .memory)
        #expect(byMemory.count == 3)
        #expect(byMemory[0].displayName == "Finder")
        #expect(byMemory[0].isProtected == true)
        #expect(byMemory[1].displayName == "Google Chrome")
        #expect(byMemory[1].processCount == 2)
        #expect(byMemory[1].totalFootprintBytes == 800_000_000)
        #expect(abs(byMemory[1].totalCPUPercent - 17.0) < 0.001)
        #expect(byMemory[1].processes[0].pid == 102)
        #expect(byMemory[2].displayName == "python3")

        let byCPU = SystemMonitorSampler.groupProcesses(entries, sortBy: .cpu)
        #expect(byCPU[0].displayName == "python3")
        #expect(byCPU[1].displayName == "Google Chrome")
        #expect(byCPU[1].processes[0].pid == 102)
        #expect(byCPU[2].displayName == "Finder")
    }

    @Test("ProcessController refuses to terminate protected processes and DiskGuard itself")
    func processControllerProtection() {
        #expect(SystemMonitorSampler.isProtectedProcess(pid: 1, uid: 0, name: "launchd", bundleID: nil) == true)
        #expect(SystemMonitorSampler.isProtectedProcess(pid: getpid(), uid: getuid(), name: "xctest", bundleID: nil) == true)
        #expect(SystemMonitorSampler.isProtectedProcess(pid: 500, uid: getuid(), name: "Finder", bundleID: "com.apple.finder") == true)
        #expect(SystemMonitorSampler.isProtectedProcess(pid: 501, uid: getuid(), name: "Google Chrome", bundleID: "com.google.Chrome") == false)

        let protectedGroup = ProcessGroup(
            id: "protected",
            displayName: "Finder",
            appBundlePath: "/System/Library/CoreServices/Finder.app",
            processes: [ProcessEntry(pid: 999999, name: "Finder", executablePath: "", appBundlePath: nil, footprintBytes: 100, cpuPercent: 0, isProtected: true)],
            totalFootprintBytes: 100,
            totalCPUPercent: 0,
            isProtected: true
        )
        let groupReport = ProcessController.terminate(group: protectedGroup, mode: .force)
        #expect(groupReport.signaledCount == 0)
        #expect(groupReport.skippedProtectedCount == 1)
        #expect(groupReport.errorMessage != nil)

        let selfProc = ProcessEntry(pid: getpid(), name: "DiskGuardTests", executablePath: "", appBundlePath: nil, footprintBytes: 100, cpuPercent: 0, isProtected: true)
        let procReport = ProcessController.terminate(process: selfProc, mode: .force)
        #expect(procReport.signaledCount == 0)
        #expect(procReport.skippedProtectedCount == 1)
    }

    @Test("NetworkStats.compute calculates rates and handles counter resets")
    func networkStatsComputation() {
        let initial = NetworkStats.compute(previousIn: nil, previousOut: nil, previousTime: nil, currentIn: 1000, currentOut: 500, currentTime: 10.0)
        #expect(initial.downloadBytesPerSec == 0)
        #expect(initial.uploadBytesPerSec == 0)

        let normal = NetworkStats.compute(previousIn: 1000, previousOut: 500, previousTime: 10.0, currentIn: 3000, currentOut: 1500, currentTime: 12.0)
        #expect(abs(normal.downloadBytesPerSec - 1000.0) < 0.001)
        #expect(abs(normal.uploadBytesPerSec - 500.0) < 0.001)

        let reset = NetworkStats.compute(previousIn: 5000, previousOut: 5000, previousTime: 12.0, currentIn: 200, currentOut: 100, currentTime: 14.0)
        #expect(reset.downloadBytesPerSec == 0)
        #expect(reset.uploadBytesPerSec == 0)
    }

    @Test("SystemMonitorSampler enumerates full process table, caches PID metadata, and pre-groups sorted views")
    func fullProcessEnumerationAndPregrouping() {
        let sampler = SystemMonitorSampler()
        let first = sampler.sample(includeTopProcesses: true, topLimit: 8)
        #expect(first.processes.count > 50)
        #expect(!first.memoryGroups.isEmpty)
        #expect(first.memoryGroups.count == first.cpuGroups.count)

        if first.memoryGroups.count >= 2 {
            #expect(first.memoryGroups[0].totalFootprintBytes >= first.memoryGroups[1].totalFootprintBytes)
        }

        let second = sampler.sample(includeTopProcesses: true, topLimit: 8)
        #expect(second.processes.count > 50)
        #expect(!second.memoryGroups.isEmpty)
        #expect(!second.cpuGroups.isEmpty)
    }

    @Test("Zero-allocation byte formatters produce clean binary memory and decimal file units")
    func byteFormattersOutput() {
        #expect(MemoryByteFormatter.string(from: 0) == "0 MB")
        #expect(MemoryByteFormatter.string(from: 14 * 1_048_576) == "14 MB")
        #expect(MemoryByteFormatter.string(from: 4 * 1_073_741_824) == "4 GB")
        #expect(MemoryByteFormatter.string(from: 1_099_511_627_776) == "1 TB")
        #expect(MemoryByteFormatter.string(from: UInt64((181.3 * 1_048_576.0).rounded())) == "181.3 MB")
        #expect(MemoryByteFormatter.string(from: UInt64((13.24 * 1_073_741_824.0).rounded())) == "13.24 GB")

        #expect(DiskByteFormatter.string(from: 0) == "Zero KB")
        #expect(DiskByteFormatter.string(from: 512) == "512 bytes")
        #expect(DiskByteFormatter.string(from: 2_000) == "2 KB")
        #expect(DiskByteFormatter.string(from: 1_500_000) == "1.5 MB")
        #expect(DiskByteFormatter.string(from: 2_500_000_000) == "2.5 GB")
    }

    @Test("parseProxySettings extracts HTTP, HTTPS, SOCKS, PAC, and disabled states")
    func proxySettingsParsing() {
        let disabled = SystemMonitorSampler.parseProxySettings([:])
        #expect(disabled.isEnabled == false)
        #expect(disabled.summary == nil)

        let combined = SystemMonitorSampler.parseProxySettings([
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": 7890,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": 7890,
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": 7891
        ])
        #expect(combined.isEnabled == true)
        #expect(combined.httpEndpoint == "127.0.0.1:7890")
        #expect(combined.httpsEndpoint == "127.0.0.1:7890")
        #expect(combined.socksEndpoint == "127.0.0.1:7891")
        #expect(combined.summary == "HTTPS 127.0.0.1:7890")

        let pacOnly = SystemMonitorSampler.parseProxySettings([
            "HTTPEnable": 0,
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString": "http://127.0.0.1:9090/proxy.pac"
        ])
        #expect(pacOnly.isEnabled == true)
        #expect(pacOnly.summary == "PAC http://127.0.0.1:9090/proxy.pac")
    }

    @Test("classifyVPNStatus prioritizes system VPN, TUN tunnel, ignores link-local utun, and detects proxy/direct")
    func vpnClassification() {
        let sysVPN = SystemMonitorSampler.classifyVPNStatus(
            primaryInterface: "en0",
            activeIPv4ByInterface: ["en0": "192.168.1.20", "utun5": "10.8.0.2"],
            connectedSystemVPN: (serviceName: "Company WireGuard", interfaceName: "utun5", virtualIP: nil),
            proxy: .disabled
        )
        #expect(sysVPN.kind == .systemVPN)
        #expect(sysVPN.isVPNActive == true)
        #expect(sysVPN.shortBadgeText == "VPN")
        #expect(sysVPN.serviceName == "Company WireGuard")
        #expect(sysVPN.virtualIP == "10.8.0.2")
        #expect(sysVPN.localIP == "192.168.1.20")

        let tunVPN = SystemMonitorSampler.classifyVPNStatus(
            primaryInterface: "en0",
            activeIPv4ByInterface: ["en0": "192.168.1.20", "utun4": "198.18.0.1"],
            connectedSystemVPN: nil,
            proxy: SystemProxyInfo(httpEndpoint: "127.0.0.1:7890", httpsEndpoint: nil, socksEndpoint: nil, pacURL: nil)
        )
        #expect(tunVPN.kind == .tunTunnel)
        #expect(tunVPN.isVPNActive == true)
        #expect(tunVPN.shortBadgeText == "VPN")
        #expect(tunVPN.interfaceName == "utun4")
        #expect(tunVPN.virtualIP == "198.18.0.1")

        let linkLocalOnly = SystemMonitorSampler.classifyVPNStatus(
            primaryInterface: "en0",
            activeIPv4ByInterface: ["en0": "192.168.1.20", "utun0": "169.254.1.2"],
            connectedSystemVPN: nil,
            proxy: .disabled
        )
        #expect(linkLocalOnly.kind == .direct)
        #expect(linkLocalOnly.isVPNActive == false)
        #expect(linkLocalOnly.shortBadgeText == nil)
        #expect(linkLocalOnly.localIP == "192.168.1.20")

        let proxyOnly = SystemMonitorSampler.classifyVPNStatus(
            primaryInterface: "en0",
            activeIPv4ByInterface: ["en0": "192.168.1.20"],
            connectedSystemVPN: nil,
            proxy: SystemProxyInfo(httpEndpoint: "127.0.0.1:7890", httpsEndpoint: nil, socksEndpoint: nil, pacURL: nil)
        )
        #expect(proxyOnly.kind == .systemProxy)
        #expect(proxyOnly.isVPNActive == false)
        #expect(proxyOnly.shortBadgeText == "代理")
    }
}
