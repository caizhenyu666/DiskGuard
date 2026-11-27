import Foundation
import SwiftUI
import AppKit
import DiskGuardCore

public enum FilterTab: String, CaseIterable, Identifiable {
    case all
    case safe
    case caution
    case readOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部"
        case .safe: return "安全缓存"
        case .caution: return "需确认"
        case .readOnly: return "空间洞察"
        }
    }

    public var tier: RiskTier? {
        switch self {
        case .all: return nil
        case .safe: return .safe
        case .caution: return .caution
        case .readOnly: return .readOnly
        }
    }
}

public enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(SemVer)
    case available(ReleaseInfo)
    case downloading(ReleaseInfo, String)
    case failed(String)
}

public enum PendingProcessAction: Identifiable {
    case forceGroup(ProcessGroup)
    case forceProcess(ProcessEntry)

    public var id: String {
        switch self {
        case .forceGroup(let group):
            return "group.\(group.id)"
        case .forceProcess(let proc):
            return "proc.\(proc.pid)"
        }
    }

    public var title: String {
        switch self {
        case .forceGroup(let group):
            return group.processCount > 1
                ? "强制结束「\(group.displayName)」全部 \(group.processCount) 个进程？"
                : "强制结束「\(group.displayName)」？"
        case .forceProcess(let proc):
            return "强制结束进程「\(proc.name)」(PID \(proc.pid))？"
        }
    }

    public var message: String {
        switch self {
        case .forceGroup(let group):
            return "将向「\(group.displayName)」的 \(group.processCount) 个进程发送强制终止信号（SIGKILL），未保存的更改可能会丢失。"
        case .forceProcess(let proc):
            return "将向进程 \(proc.name)（PID \(proc.pid)）发送强制终止信号（SIGKILL），未保存的更改可能会丢失。"
        }
    }
}

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var volumeStats: VolumeStats = DiskScanner.readVolumeStats()
    @Published public var fdaStatus: FDAStatus = .granted
    @Published public var items: [ScanItem] = []
    @Published public var selectedIDs: Set<String> = []
    @Published public var activeFilter: FilterTab = .all {
        didSet {
            guard !isInitializing else { return }
            preferences.activeFilterRawValue = activeFilter.rawValue
        }
    }
    @Published public var searchText: String = ""
    @Published public var isScanning: Bool = false
    @Published public var scanProgressText: String = "准备就绪"
    @Published public var scanDuration: TimeInterval?
    @Published public var isCleaning: Bool = false
    @Published public var cleanProgress: Double = 0
    @Published public var logs: [LogEntry] = []
    @Published public var isLogDrawerExpanded: Bool = false {
        didSet {
            guard !isInitializing else { return }
            preferences.isLogDrawerExpanded = isLogDrawerExpanded
        }
    }
    @Published public var appearanceMode: AppearanceMode = .system {
        didSet {
            guard !isInitializing else { return }
            preferences.appearanceMode = appearanceMode
            applyAppAppearance()
        }
    }
    @Published public var pendingCleanItems: [ScanItem]?
    @Published public var activeBrowser: BrowserContext?
    @Published public var updateState: UpdateState = .idle
    @Published public var showingUpdateSheet: Bool = false
    @Published public var activeSection: MainSectionTab = .storage {
        didSet {
            guard !isInitializing else { return }
            preferences.activeMainSectionRawValue = activeSection.rawValue
        }
    }
    @Published public var systemSnapshot: SystemSnapshot
    @Published public var cpuHistory: [Double] = []
    @Published public var memoryHistory: [Double] = []
    @Published public var networkDownHistory: [Double] = []
    @Published public var processSearchText: String = ""
    @Published public var onlyClosableProcesses: Bool = false
    @Published public var pendingProcessTermination: PendingProcessAction?
    @Published public var isMainWindowMinimized: Bool = false
    @Published public var hudDismissedForCurrentMinimize: Bool = false
    @Published public var floatingHUDOnMinimize: Bool = true {
        didSet {
            guard !isInitializing else { return }
            preferences.floatingHUDOnMinimize = floatingHUDOnMinimize
        }
    }
    @Published public var floatingHUDAlwaysOn: Bool = false {
        didSet {
            guard !isInitializing else { return }
            preferences.floatingHUDAlwaysOn = floatingHUDAlwaysOn
        }
    }
    @Published public var floatingHUDStyle: FloatingHUDStyle = .transparent {
        didSet {
            guard !isInitializing else { return }
            preferences.floatingHUDStyle = floatingHUDStyle
        }
    }
    @Published public var floatingHUDCollapsed: Bool = false {
        didSet {
            guard !isInitializing else { return }
            preferences.floatingHUDCollapsed = floatingHUDCollapsed
        }
    }
    @Published public var collapsedTiers: Set<RiskTier> = [] {
        didSet {
            guard !isInitializing else { return }
            preferences.collapsedTiers = collapsedTiers
        }
    }

    public let sizeCache = DirectorySizeCache()
    public let currentVersion: SemVer = AppUpdater.currentAppVersion()
    public let currentBuildNumber: String = AppUpdater.currentBuildNumber()

    private let preferences: UserPreferences
    private let systemSampler: SystemMonitorSampler
    private var isInitializing = true
    private var scanTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var hasAutoCheckedUpdate = false
    private var scanGeneration: UInt64 = 0
    private var streamedByID: [String: ScanItem] = [:]
    private var lastStreamPublish: ContinuousClock.Instant?

    public init(preferences: UserPreferences = UserPreferences()) {
        let sampler = SystemMonitorSampler()
        self.systemSampler = sampler
        self.systemSnapshot = sampler.sample(includeTopProcesses: false)
        self.preferences = preferences
        self.appearanceMode = preferences.appearanceMode
        self.collapsedTiers = preferences.collapsedTiers
        self.activeFilter = FilterTab(rawValue: preferences.activeFilterRawValue) ?? .all
        self.isLogDrawerExpanded = preferences.isLogDrawerExpanded
        self.floatingHUDOnMinimize = preferences.floatingHUDOnMinimize
        self.floatingHUDAlwaysOn = preferences.floatingHUDAlwaysOn
        self.floatingHUDStyle = preferences.floatingHUDStyle
        self.floatingHUDCollapsed = preferences.floatingHUDCollapsed
        self.activeSection = MainSectionTab(rawValue: preferences.activeMainSectionRawValue) ?? .storage
        self.isInitializing = false
        applyAppAppearance()
    }

    public func applyAppAppearance() {
        switch appearanceMode {
        case .system:
            NSApp?.appearance = nil
        case .light:
            NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    public var selectedItems: [ScanItem] {
        items.filter { selectedIDs.contains($0.id) && $0.isSelectable }
    }

    public var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public var trashBytes: Int64 {
        items.first(where: { $0.id == "tier3.trash" })?.sizeBytes ?? 0
    }

    public var projectedAvailableBytes: Int64 {
        volumeStats.importantAvailableBytes + selectedBytes
    }

    public func items(for tier: RiskTier) -> [ScanItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard item.tier == tier else { return false }
            if query.isEmpty { return true }
            return item.title.localizedCaseInsensitiveContains(query)
                || item.subtitle.localizedCaseInsensitiveContains(query)
                || item.displayPathURL.path.localizedCaseInsensitiveContains(query)
        }
    }

    public func count(for tab: FilterTab) -> Int {
        guard let tier = tab.tier else { return items.count }
        return items.filter { $0.tier == tier }.count
    }

    public func totalBytes(for tier: RiskTier) -> Int64 {
        items(for: tier).reduce(0) { $0 + $1.sizeBytes }
    }

    public var maxVisibleSizeBytes: Int64 {
        let visibleTiers: [RiskTier] = activeFilter.tier.map { [$0] } ?? RiskTier.allCases
        let visible = visibleTiers.flatMap { items(for: $0) }
        return max(1, visible.map(\.sizeBytes).max() ?? 1)
    }

    public func startScan() {
        scanTask?.cancel()
        refreshTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration

        sizeCache.clear()
        streamedByID.removeAll()
        lastStreamPublish = nil
        isScanning = true
        scanProgressText = "正在启动扫描..."

        let cache = sizeCache
        scanTask = Task {
            let scanner = DiskScanner()
            let result = await scanner.scanAll(
                sizeCache: cache,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanGeneration == generation, self.isScanning else { return }
                        self.scanProgressText = progress
                    }
                },
                onBatch: { [weak self] batch in
                    Task { @MainActor [weak self] in
                        self?.mergeStreamedBatch(batch, generation: generation)
                    }
                }
            )
            if Task.isCancelled { return }
            guard self.scanGeneration == generation else { return }

            self.volumeStats = result.volumeStats
            self.fdaStatus = result.fdaStatus
            self.items = result.items
            self.scanDuration = result.durationSeconds
            self.isScanning = false
            self.scanProgressText = String(format: "扫描完成 (%.1f 秒)", result.durationSeconds)

            let validSelectableIDs = Set(result.items.filter(\.isSelectable).map(\.id))
            self.selectedIDs = self.selectedIDs.intersection(validSelectableIDs)

            self.appendLog(
                level: .info,
                message: String(format: "扫描完成（%.1f 秒），共发现 %d 个项目。", result.durationSeconds, result.items.count)
            )
        }
    }

    private func mergeStreamedBatch(_ batch: [ScanItem], generation: UInt64) {
        guard scanGeneration == generation, isScanning, !batch.isEmpty else { return }
        let wasEmpty = streamedByID.isEmpty
        for item in batch {
            streamedByID[item.id] = item
        }
        let now = ContinuousClock.now
        let shouldPublish = wasEmpty || lastStreamPublish.map { now - $0 >= .milliseconds(100) } ?? true
        if shouldPublish {
            lastStreamPublish = now
            self.items = DiskScanner.deduplicateAndSort(Array(streamedByID.values))
        }
    }

    public func selectAllSafe() {
        var added = 0
        var skippedRunning = 0
        for item in items where item.tier == .safe && item.isSelectable {
            if item.runningAppWarning == nil {
                if selectedIDs.insert(item.id).inserted {
                    added += 1
                }
            } else {
                skippedRunning += 1
            }
        }
        if skippedRunning > 0 {
            appendLog(level: .info, message: "「全选安全项」已自动跳过 \(skippedRunning) 个正在运行中的应用缓存（可手动单独勾选）。")
        } else if added > 0 {
            appendLog(level: .info, message: "已选中全部 \(added) 项可安全重建缓存。")
        }
    }

    public func deselectAll() {
        selectedIDs.removeAll()
    }

    public func toggleSelection(id: String) {
        guard let item = items.first(where: { $0.id == id }), item.isSelectable else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    public func toggleSection(_ tier: RiskTier) {
        if collapsedTiers.contains(tier) {
            collapsedTiers.remove(tier)
        } else {
            collapsedTiers.insert(tier)
        }
    }

    public func requestCleanSelected() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        pendingCleanItems = targets
    }

    public func requestCleanSingle(_ item: ScanItem) {
        guard item.isSelectable else { return }
        pendingCleanItems = [item]
    }

    public func cancelPendingClean() {
        pendingCleanItems = nil
    }

    public func executePendingClean() {
        guard let targets = pendingCleanItems, !targets.isEmpty else { return }
        pendingCleanItems = nil
        isCleaning = true
        cleanProgress = 0
        isLogDrawerExpanded = true

        appendLog(level: .info, message: "开始安全清理（共 \(targets.count) 项，全部仅移入废纸篓）...")

        let cache = sizeCache
        Task {
            let safety = SafetyGuard()
            let total = targets.count
            var totalReclaimed: Int64 = 0
            var totalTrashed = 0
            var totalSkipped = 0

            for (index, item) in targets.enumerated() {
                let report = await Task.detached(priority: .userInitiated) {
                    safety.trash(
                        item: item,
                        sizeEstimator: { url in
                            cache.size(for: url) ?? SafetyGuard.defaultSizeBytes(at: url)
                        }
                    )
                }.value

                totalReclaimed += report.reclaimedBytes
                totalTrashed += report.trashedCount
                totalSkipped += report.skippedCount

                for entry in report.messages {
                    self.logs.append(entry)
                }
                self.cleanProgress = Double(index + 1) / Double(total)
                if report.trashedCount > 0 {
                    self.selectedIDs.remove(item.id)
                }
            }

            self.isCleaning = false
            self.appendLog(
                level: .success,
                message: "清理完成：共将 \(totalTrashed) 项安全移入废纸篓（合计 \(DiskByteFormatter.string(from: totalReclaimed))，跳过 \(totalSkipped) 项）。请在访达「清倒废纸篓」后正式释放空间。"
            )

            let affectedURLs = targets.flatMap(\.targets)
            await self.performIncrementalRefresh(affectedPaths: affectedURLs, includeTrash: true)
        }
    }

    public func revealInFinder(_ item: ScanItem) {
        let url = item.displayPathURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([item.allowedRoot])
        }
    }

    public func copyPath(_ item: ScanItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.displayPathURL.path, forType: .string)
        appendLog(level: .info, message: "已复制路径：\(item.displayPathURL.path)")
    }

    public func openTrashInApp() {
        activeBrowser = .trash
    }

    public func canBrowseInApp(_ item: ScanItem) -> Bool {
        if item.id == "tier3.trash" { return true }
        let path = item.displayPathURL.standardizedFileURL.path
        if path == "/" { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let vals = try? item.displayPathURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        return vals?.isSymbolicLink != true
    }

    public func openFolderInApp(_ item: ScanItem) {
        if item.id == "tier3.trash" {
            activeBrowser = .trash
            return
        }
        guard canBrowseInApp(item) else {
            revealInFinder(item)
            return
        }
        activeBrowser = .folder(
            title: item.title,
            rootURL: item.displayPathURL,
            tier: item.tier,
            allowedRoot: item.allowedRoot,
            lockReason: item.lockReason
        )
    }

    public func appendLogs(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        logs.append(contentsOf: entries)
        isLogDrawerExpanded = true
    }

    public func refreshAfterBrowserMutation(affectedPaths: [URL] = [], includeTrash: Bool = true) {
        refreshTask?.cancel()
        refreshTask = Task {
            await performIncrementalRefresh(affectedPaths: affectedPaths, includeTrash: includeTrash)
        }
    }

    private func performIncrementalRefresh(affectedPaths: [URL], includeTrash: Bool) async {
        guard !isScanning else { return }
        let scanner = DiskScanner()
        let refreshed = await scanner.refreshTargets(
            existingItems: items,
            affectedPaths: affectedPaths,
            includeTrash: includeTrash,
            fdaStatus: fdaStatus,
            sizeCache: sizeCache
        )
        if Task.isCancelled || isScanning { return }

        self.volumeStats = refreshed.volumeStats
        self.items = refreshed.items
        let validSelectableIDs = Set(refreshed.items.filter(\.isSelectable).map(\.id))
        self.selectedIDs = self.selectedIDs.intersection(validSelectableIDs)
        self.scanProgressText = "已增量更新（共 \(refreshed.items.count) 项）"
    }

    public func openTrashInFinder() {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        NSWorkspace.shared.open(trashURL)
    }

    public func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - App Updates

    public func checkForUpdatesOnLaunchIfNeeded() {
        guard !hasAutoCheckedUpdate else { return }
        hasAutoCheckedUpdate = true
        checkForUpdates(silent: true)
    }

    public func handleVersionBadgeTap() {
        if case .available = updateState {
            showingUpdateSheet = true
        } else {
            checkForUpdates(silent: false)
        }
    }

    public func checkForUpdates(silent: Bool = false) {
        if case .downloading = updateState { return }
        updateTask?.cancel()
        if !silent {
            updateState = .checking
        }

        let current = currentVersion
        updateTask = Task {
            let updater = AppUpdater()
            do {
                let outcome = try await updater.checkForUpdates(currentVersion: current)
                if Task.isCancelled { return }
                switch outcome {
                case .updateAvailable(_, let release):
                    self.updateState = .available(release)
                    self.appendLog(level: .info, message: "发现 DiskGuard 新版本 \(release.tagName)（当前 \(current.displayTag)）。")
                    if !silent {
                        self.showingUpdateSheet = true
                    }
                case .upToDate(_, let latest):
                    self.updateState = .upToDate(latest)
                    if !silent {
                        self.appendLog(level: .info, message: "当前 \(current.displayTag) 已是最新版本（最新发布 \(latest.displayTag)）。")
                    }
                case .noReleasesYet:
                    self.updateState = .upToDate(current)
                    if !silent {
                        self.appendLog(level: .info, message: "仓库尚无正式发布的 Release（当前版本 \(current.displayTag)）。")
                    }
                }
            } catch {
                if Task.isCancelled { return }
                let msg = error.localizedDescription
                if silent {
                    self.updateState = .idle
                } else {
                    self.updateState = .failed(msg)
                    self.appendLog(level: .warning, message: "检查更新失败：\(msg)")
                    self.isLogDrawerExpanded = true
                }
            }
        }
    }

    public func performUpdate(_ release: ReleaseInfo) {
        if case .downloading = updateState { return }
        updateTask?.cancel()
        updateState = .downloading(release, "正在初始化更新...")

        updateTask = Task {
            let updater = AppUpdater()
            do {
                let prepared = try await updater.downloadAndPrepareUpdate(release: release) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .downloading = self.updateState {
                            self.updateState = .downloading(release, progress)
                        }
                    }
                }
                if Task.isCancelled { return }
                self.updateState = .downloading(release, "验证通过，正在替换并重启...")
                try updater.installAndRelaunch(prepared: prepared, targetAppURL: Bundle.main.bundleURL)
                self.appendLog(level: .success, message: "正在重启并升级至 \(release.tagName)...")
                self.showingUpdateSheet = false
                self.scanTask?.cancel()
                self.refreshTask?.cancel()
                self.stopSystemMonitoring()
                for window in NSApp.windows {
                    window.orderOut(nil)
                    window.close()
                }
                NSApp.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    exit(0)
                }
            } catch {
                if Task.isCancelled { return }
                let msg = error.localizedDescription
                self.updateState = .failed(msg)
                self.appendLog(level: .error, message: "更新失败：\(msg)")
                self.isLogDrawerExpanded = true
            }
        }
    }

    // MARK: - System Monitor & Floating HUD

    public var shouldShowFloatingHUD: Bool {
        floatingHUDAlwaysOn || (floatingHUDOnMinimize && isMainWindowMinimized && !hudDismissedForCurrentMinimize)
    }

    public func setMainWindowMinimized(_ minimized: Bool) {
        isMainWindowMinimized = minimized
        if !minimized {
            hudDismissedForCurrentMinimize = false
        }
    }

    public func toggleFloatingHUDPin() {
        floatingHUDAlwaysOn.toggle()
    }

    public func toggleFloatingHUDCollapsed() {
        floatingHUDCollapsed.toggle()
    }

    public func dismissFloatingHUD() {
        floatingHUDAlwaysOn = false
        if isMainWindowMinimized {
            hudDismissedForCurrentMinimize = true
        }
    }

    public var memoryProcessGroups: [ProcessGroup] {
        filteredProcessGroups(sortedBy: .memory)
    }

    public var cpuProcessGroups: [ProcessGroup] {
        filteredProcessGroups(sortedBy: .cpu)
    }

    private func filteredProcessGroups(sortedBy metric: ProcessSortMetric) -> [ProcessGroup] {
        let grouped = SystemMonitorSampler.groupProcesses(systemSnapshot.processes, sortBy: metric)
        let query = processSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return grouped.filter { group in
            if onlyClosableProcesses && group.isProtected {
                return false
            }
            if query.isEmpty { return true }
            if group.displayName.localizedCaseInsensitiveContains(query) {
                return true
            }
            return group.processes.contains { proc in
                proc.name.localizedCaseInsensitiveContains(query) || String(proc.pid).contains(query)
            }
        }
    }

    public func terminateGroup(_ group: ProcessGroup, mode: ProcessController.TerminateMode) {
        if mode == .force {
            pendingProcessTermination = .forceGroup(group)
            return
        }
        executeTerminateGroup(group, mode: mode)
    }

    public func terminateProcess(_ process: ProcessEntry, mode: ProcessController.TerminateMode) {
        if mode == .force {
            pendingProcessTermination = .forceProcess(process)
            return
        }
        executeTerminateProcess(process, mode: mode)
    }

    public func cancelPendingProcessTermination() {
        pendingProcessTermination = nil
    }

    public func confirmPendingProcessTermination() {
        guard let action = pendingProcessTermination else { return }
        pendingProcessTermination = nil
        switch action {
        case .forceGroup(let group):
            executeTerminateGroup(group, mode: .force)
        case .forceProcess(let proc):
            executeTerminateProcess(proc, mode: .force)
        }
    }

    private func executeTerminateGroup(_ group: ProcessGroup, mode: ProcessController.TerminateMode) {
        Task {
            let report = await DiskScanner.runOnIOQueue {
                ProcessController.terminate(group: group, mode: mode)
            }
            if report.signaledCount > 0 {
                self.appendLog(
                    level: .success,
                    message: "已\(mode.actionLabel)「\(report.targetName)」共 \(report.signaledCount) 个进程。"
                )
            } else {
                self.appendLog(
                    level: .warning,
                    message: report.errorMessage ?? "未能\(mode.actionLabel)「\(report.targetName)」。"
                )
            }
            try? await Task.sleep(for: .milliseconds(450))
            await self.sampleSystemNow(includeProcesses: true)
        }
    }

    private func executeTerminateProcess(_ process: ProcessEntry, mode: ProcessController.TerminateMode) {
        Task {
            let report = await DiskScanner.runOnIOQueue {
                ProcessController.terminate(process: process, mode: mode)
            }
            if report.signaledCount > 0 {
                self.appendLog(
                    level: .success,
                    message: "已\(mode.actionLabel)进程「\(report.targetName)」(PID \(process.pid))。"
                )
            } else {
                self.appendLog(
                    level: .warning,
                    message: report.errorMessage ?? "未能\(mode.actionLabel)进程「\(report.targetName)」。"
                )
            }
            try? await Task.sleep(for: .milliseconds(450))
            await self.sampleSystemNow(includeProcesses: true)
        }
    }

    public func startSystemMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            var tickCount = 0
            while !Task.isCancelled {
                guard let self else { return }
                let minimized = self.isMainWindowMinimized
                let onProcessTab = (self.activeSection == .memory || self.activeSection == .cpu)
                let needProcesses = !minimized && (onProcessTab || tickCount % 3 == 0)
                let refreshDisk = (tickCount > 0 && tickCount % 10 == 0 && !self.isScanning && !self.isCleaning)

                await self.sampleSystemNow(includeProcesses: needProcesses)
                if Task.isCancelled { return }

                if refreshDisk {
                    let stats = await DiskScanner.runOnIOQueue {
                        DiskScanner.readVolumeStats()
                    }
                    if !Task.isCancelled {
                        self.volumeStats = stats
                    }
                }

                tickCount &+= 1
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    public func sampleSystemNow(includeProcesses: Bool) async {
        let sampler = systemSampler
        let sampled = await DiskScanner.runOnIOQueue {
            sampler.sample(includeTopProcesses: includeProcesses, topLimit: 8)
        }
        if Task.isCancelled { return }

        let mergedSnapshot = SystemSnapshot(
            timestamp: sampled.timestamp,
            memory: sampled.memory,
            cpu: sampled.cpu,
            topProcesses: includeProcesses ? sampled.topProcesses : self.systemSnapshot.topProcesses,
            processes: includeProcesses ? sampled.processes : self.systemSnapshot.processes,
            health: sampled.health
        )
        self.systemSnapshot = mergedSnapshot
        self.appendMonitorSample(mergedSnapshot.cpu.totalUsage, to: &self.cpuHistory)
        self.appendMonitorSample(mergedSnapshot.memory.usedRatio, to: &self.memoryHistory)
        self.appendMonitorSample(mergedSnapshot.health.network.downloadBytesPerSec, to: &self.networkDownHistory)
    }

    public func stopSystemMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func appendMonitorSample(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > 24 {
            history.removeFirst(history.count - 24)
        }
    }

    private func appendLog(level: LogLevel, message: String) {
        logs.append(LogEntry(level: level, message: message))
    }
}
