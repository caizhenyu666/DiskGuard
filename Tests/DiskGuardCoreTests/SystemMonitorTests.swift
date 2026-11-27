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
    }
}
