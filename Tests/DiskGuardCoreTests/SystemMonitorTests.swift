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

        reloaded.activeMainSectionRawValue = "memory"
        reloaded.floatingHUDCollapsed = true

        let secondReload = UserPreferences(suiteName: suite)
        #expect(secondReload.activeMainSectionRawValue == "memory")
        #expect(secondReload.floatingHUDCollapsed == true)
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
}
