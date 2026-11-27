import Foundation
import CoreGraphics
import Testing
@testable import DiskGuardCore

@Suite("DesktopPet State Machine, Packs & Preferences Tests")
struct DesktopPetTests {
    private func makeInput(
        cpuUsage: Double = 0.15,
        memoryUsedRatio: Double = 0.45,
        memoryPressure: MemoryPressure = .normal,
        thermal: ThermalLevel = .nominal,
        diskAvailableBytes: Int64 = 120_000_000_000,
        batteryPercent: Int? = 80,
        batteryIsPluggedIn: Bool = true,
        localHour: Int = 14,
        localMinute: Int = 0,
        isHappyBoostActive: Bool = false
    ) -> PetMoodInput {
        PetMoodInput(
            cpuUsage: cpuUsage,
            memoryUsedRatio: memoryUsedRatio,
            memoryPressure: memoryPressure,
            thermal: thermal,
            diskAvailableBytes: diskAvailableBytes,
            batteryPercent: batteryPercent,
            batteryIsPluggedIn: batteryIsPluggedIn,
            localHour: localHour,
            localMinute: localMinute,
            isHappyBoostActive: isHappyBoostActive
        )
    }

    @Test("PetMoodEvaluator applies exact priority and boundary thresholds")
    func moodEvaluationPrioritiesAndThresholds() {
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput()) == .idle)

        // Happy boost overrides stressed, busy, and sleepy
        #expect(
            PetMoodEvaluator.evaluateRaw(
                input: makeInput(
                    cpuUsage: 0.95,
                    memoryUsedRatio: 0.95,
                    memoryPressure: .critical,
                    thermal: .critical,
                    diskAvailableBytes: 2_000_000_000,
                    isHappyBoostActive: true
                )
            ) == .happy
        )

        // Stressed overrides busy: memory critical
        #expect(
            PetMoodEvaluator.evaluateRaw(
                input: makeInput(cpuUsage: 0.90, memoryPressure: .critical)
            ) == .stressed
        )

        // Warning pressure boundary at 0.85
        #expect(
            PetMoodEvaluator.evaluateRaw(
                input: makeInput(memoryUsedRatio: 0.849, memoryPressure: .warning)
            ) == .idle
        )
        #expect(
            PetMoodEvaluator.evaluateRaw(
                input: makeInput(memoryUsedRatio: 0.85, memoryPressure: .warning)
            ) == .stressed
        )

        // Low disk boundary at 15 GB (ignores 0 unknown)
        #expect(
            PetMoodEvaluator.evaluateRaw(
                input: makeInput(diskAvailableBytes: 15_000_000_000)
            ) == .idle
        )
        #expect(
            PetMoodEvaluator.evaluateRaw(
                input: makeInput(diskAvailableBytes: 14_999_999_999)
            ) == .stressed
        )
        #expect(
            PetMoodEvaluator.evaluateRaw(
                input: makeInput(diskAvailableBytes: 0)
            ) == .idle
        )

        // Busy boundary: CPU 0.64 vs 0.65 and serious thermal
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(cpuUsage: 0.649)) == .idle)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(cpuUsage: 0.65)) == .busy)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(thermal: .serious)) == .busy)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(thermal: .critical)) == .busy)

        // Late night window 23:30 - 05:30 with low CPU (< 0.30)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(localHour: 23, localMinute: 29)) == .idle)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(localHour: 23, localMinute: 30)) == .sleepy)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(localHour: 2, localMinute: 15)) == .sleepy)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(localHour: 5, localMinute: 29)) == .sleepy)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(localHour: 5, localMinute: 30)) == .idle)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(cpuUsage: 0.35, localHour: 1, localMinute: 0)) == .idle)

        // Low battery unplugged (< 20%)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(batteryPercent: 19, batteryIsPluggedIn: false)) == .sleepy)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(batteryPercent: 20, batteryIsPluggedIn: false)) == .idle)
        #expect(PetMoodEvaluator.evaluateRaw(input: makeInput(batteryPercent: 10, batteryIsPluggedIn: true)) == .idle)
    }

    @Test("PetMoodStabilizer enforces minimum hold duration except immediate happy/stressed transitions")
    func moodStabilizerDebouncing() {
        let start = Date(timeIntervalSince1970: 1_000)
        var stabilizer = PetMoodStabilizer(initialMood: .idle, lastTransitionDate: start, minimumHoldSeconds: 5.0)

        // Busy within hold window stays idle
        #expect(stabilizer.update(rawMood: .busy, now: start.addingTimeInterval(2.0)) == .idle)
        // Busy after 5s transitions
        #expect(stabilizer.update(rawMood: .busy, now: start.addingTimeInterval(5.0)) == .busy)
        // Idle right after busy holds busy
        #expect(stabilizer.update(rawMood: .idle, now: start.addingTimeInterval(7.0)) == .busy)
        // Happy and stressed transition immediately
        #expect(stabilizer.update(rawMood: .happy, now: start.addingTimeInterval(7.5)) == .happy)
        #expect(stabilizer.update(rawMood: .stressed, now: start.addingTimeInterval(8.0)) == .stressed)
    }

    @Test("PetPack single-image fallback uses idle.png for missing moods and PetPackManifest round-trips")
    func petPackSingleImageFallbackAndManifestCodable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskguard-petpack-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let idleURL = tempDir.appendingPathComponent("idle.png")
        let happyURL = tempDir.appendingPathComponent("happy.png")
        try Data("idle".utf8).write(to: idleURL)
        try Data("happy".utf8).write(to: happyURL)

        let pack = PetPack(
            id: "daughter-chibi",
            name: "宝贝",
            isBuiltIn: false,
            directoryURL: tempDir,
            moodFiles: [
                .idle: "idle.png",
                .happy: "happy.png"
            ]
        )

        #expect(pack.hasDedicatedArtwork(for: .idle) == true)
        #expect(pack.hasDedicatedArtwork(for: .happy) == true)
        #expect(pack.hasDedicatedArtwork(for: .busy) == false)

        #expect(pack.imageURL(for: .idle) == idleURL)
        #expect(pack.imageURL(for: .happy) == happyURL)
        #expect(pack.imageURL(for: .busy) == idleURL)
        #expect(pack.imageURL(for: .stressed) == idleURL)
        #expect(pack.imageURL(for: .sleepy) == idleURL)

        let manifest = PetPackManifest(
            id: "daughter-chibi",
            name: "宝贝",
            version: 1,
            moodFiles: ["idle": "idle.png", "happy": "happy.png"]
        )
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(PetPackManifest.self, from: encoded)
        #expect(decoded == manifest)
    }

    @Test("UserPreferences persists floatingHUDMode, activePetID, petDisplaySize, origin, and legacy collapsed fallback")
    func petPreferencesPersistence() {
        let suite = "com.local.diskguard.petprefs.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let prefs = UserPreferences(suiteName: suite)
        #expect(prefs.floatingHUDMode == .pet)
        #expect(prefs.activePetID == PetPack.builtInWestieID)
        #expect(prefs.petDisplaySize == .medium)
        #expect(prefs.floatingHUDOrigin == nil)

        // Legacy collapsed fallback when floatingHUDMode was never explicitly written
        prefs.floatingHUDCollapsed = true
        #expect(prefs.floatingHUDMode == .pill)

        prefs.floatingHUDMode = .expanded
        prefs.activePetID = "custom-daughter"
        prefs.petDisplaySize = .large
        prefs.floatingHUDOrigin = CGPoint(x: 1240.5, y: 820.0)

        let reloaded = UserPreferences(suiteName: suite)
        #expect(reloaded.floatingHUDMode == .expanded)
        #expect(reloaded.activePetID == "custom-daughter")
        #expect(reloaded.petDisplaySize == .large)
        #expect(reloaded.floatingHUDOrigin == CGPoint(x: 1240.5, y: 820.0))
    }
}
