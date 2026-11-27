import Foundation
import AppKit

public final class DiskScanner: Sendable {
    public let homeDirectory: URL
    public let applicationsDirectory: URL
    public let systemLibraryDirectory: URL
    public let minicondaPkgsDirectory: URL

    private static let ioQueue = DispatchQueue(
        label: "com.local.diskguard.scanner.io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications"),
        systemLibraryDirectory: URL = URL(fileURLWithPath: "/Library"),
        minicondaPkgsDirectory: URL = URL(fileURLWithPath: "/opt/miniconda3/pkgs")
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.applicationsDirectory = applicationsDirectory.standardizedFileURL
        self.systemLibraryDirectory = systemLibraryDirectory.standardizedFileURL
        self.minicondaPkgsDirectory = minicondaPkgsDirectory.standardizedFileURL
    }

    public static func runOnIOQueue<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    public static func readVolumeStats(at url: URL = URL(fileURLWithPath: "/")) -> VolumeStats {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return VolumeStats(totalBytes: 0, importantAvailableBytes: 0, physicalAvailableBytes: 0)
        }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        let physical = Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeStats(
            totalBytes: total,
            importantAvailableBytes: important,
            physicalAvailableBytes: physical
        )
    }

    public static func checkFullDiskAccess(home: URL) -> FDAStatus {
        let probes: [(name: String, url: URL)] = [
            ("~/Downloads", home.appendingPathComponent("Downloads")),
            ("~/Library/Application Support", home.appendingPathComponent("Library/Application Support")),
            ("~/.Trash", home.appendingPathComponent(".Trash"))
        ]
        let fm = FileManager.default
        var blocked: [String] = []
        for probe in probes {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: probe.url.path, isDirectory: &isDir) {
                continue
            }
            do {
                _ = try fm.contentsOfDirectory(atPath: probe.url.path)
            } catch {
                blocked.append(probe.name)
            }
        }
        return blocked.isEmpty ? .granted : .missing(blockedPaths: blocked)
    }

    public static func directorySize(at url: URL) -> Int64 {
        FastDirectorySizer.directorySize(at: url, cache: nil, cacheDepth: 0)
    }

    public static func directorySize(
        at url: URL,
        cache: DirectorySizeCache?,
        cacheDepth: Int = 3,
        cancelFlag: AtomicCancelFlag? = nil
    ) -> Int64 {
        FastDirectorySizer.directorySize(
            at: url,
            cache: cache,
            cacheDepth: cacheDepth,
            cancelFlag: cancelFlag
        )
    }

    public static func runningAppNames() -> Set<String> {
        var names = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName?.lowercased() {
                names.insert(name)
            }
            if let bundleID = app.bundleIdentifier?.lowercased() {
                names.insert(bundleID)
            }
        }
        return names
    }

    public static func runCommandWithTimeout(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 2.0
    ) -> (exitCode: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            process.terminate()
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    public static func isWorktreeDirty(at url: URL) -> Bool {
        guard let result = runCommandWithTimeout(
            executable: "/usr/bin/git",
            arguments: ["-C", url.path, "status", "--porcelain"],
            timeoutSeconds: 2.0
        ) else {
            return true // Fail-safe: treat timeout/error as dirty
        }
        if result.exitCode != 0 {
            return true
        }
        return !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func chromeCodeSignCloneCount() -> Int {
        let cloneRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .deletingLastPathComponent()
            .appendingPathComponent("X/com.google.Chrome.code_sign_clone")
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: cloneRoot.path) else {
            return 0
        }
        return children.count
    }

    public static func localUpdateSnapshots() -> [String] {
        guard let result = runCommandWithTimeout(
            executable: "/usr/bin/tmutil",
            arguments: ["listlocalsnapshots", "/"],
            timeoutSeconds: 2.0
        ), result.exitCode == 0 else {
            return []
        }
        return result.output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("com.apple.") }
    }

    public static func filterCondaArchives(in pkgsURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: pkgsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return children.filter { url in
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard vals?.isSymbolicLink != true, vals?.isRegularFile == true else {
                return false
            }
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".tar.bz2") || name.hasSuffix(".conda") else {
                return false
            }
            return fm.isWritableFile(atPath: url.path)
        }
    }

    public static func filterOldDownloads(
        in downloadsURL: URL,
        now: Date = Date(),
        olderThanDays: Int = 7
    ) -> [(url: URL, modified: Date, sizeBytes: Int64)] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let cutoff = now.addingTimeInterval(-Double(olderThanDays) * 86_400)
        var results: [(url: URL, modified: Date, sizeBytes: Int64)] = []
        for url in children {
            let ext = url.pathExtension.lowercased()
            guard ext == "dmg" || ext == "pkg" else { continue }
            guard let vals = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey
            ]) else { continue }
            guard vals.isSymbolicLink != true, vals.isRegularFile == true else { continue }
            let modDate = vals.contentModificationDate ?? now
            guard modDate < cutoff else { continue }
            let size = Int64(vals.totalFileAllocatedSize ?? vals.fileAllocatedSize ?? 0)
            results.append((url, modDate, size))
        }
        return results
    }

    public static func discoverUnityProjects(in home: URL) -> [URL] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return children.filter { dir in
            let vals = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard vals?.isSymbolicLink != true, vals?.isDirectory == true else { return false }
            var assetsIsDir: ObjCBool = false
            var settingsIsDir: ObjCBool = false
            let hasAssets = fm.fileExists(atPath: dir.appendingPathComponent("Assets").path, isDirectory: &assetsIsDir) && assetsIsDir.boolValue
            let hasSettings = fm.fileExists(atPath: dir.appendingPathComponent("ProjectSettings").path, isDirectory: &settingsIsDir) && settingsIsDir.boolValue
            return hasAssets && hasSettings
        }
    }

    public static func isUnityProjectLocked(_ projectURL: URL) -> Bool {
        let lockfile = projectURL.appendingPathComponent("Temp/UnityLockfile")
        return FileManager.default.fileExists(atPath: lockfile.path)
    }

    public static func modificationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public static func listImmediateEntries(at directory: URL) throws -> [DirectoryEntry] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .contentModificationDateKey
        ]
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        )

        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(children.count)

        for child in children {
            let name = child.lastPathComponent
            if name == ".DS_Store" || name == ".localized" {
                continue
            }
            let vals = try? child.resourceValues(forKeys: Set(keys))
            let isSymlink = vals?.isSymbolicLink == true
            let isDir = !isSymlink && (vals?.isDirectory == true)
            let size: Int64? = if isSymlink {
                0
            } else if isDir {
                nil
            } else {
                Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0)
            }
            entries.append(DirectoryEntry(
                url: child,
                name: name,
                isDirectory: isDir,
                isSymbolicLink: isSymlink,
                isHidden: name.hasPrefix("."),
                sizeBytes: size,
                modifiedDate: vals?.contentModificationDate
            ))
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let ls = lhs.sizeBytes ?? 0
            let rs = rhs.sizeBytes ?? 0
            if ls != rs {
                return ls > rs
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    public func scanAll(
        sizeCache: DirectorySizeCache? = nil,
        onProgress: @escaping @Sendable (String) -> Void,
        onBatch: (@Sendable ([ScanItem]) -> Void)? = nil
    ) async -> ScanResult {
        let start = Date()
        onProgress("正在读取磁盘容量与系统权限...")

        let cancelFlag = AtomicCancelFlag()

        return await withTaskCancellationHandler {
            let (volumeStats, fdaStatus, runningApps, unityProjects) = await Self.runOnIOQueue {
                (
                    Self.readVolumeStats(),
                    Self.checkFullDiskAccess(home: self.homeDirectory),
                    Self.runningAppNames(),
                    Self.discoverUnityProjects(in: self.homeDirectory)
                )
            }

            if Task.isCancelled {
                cancelFlag.cancel()
                return ScanResult(
                    volumeStats: volumeStats,
                    fdaStatus: fdaStatus,
                    items: [],
                    durationSeconds: Date().timeIntervalSince(start)
                )
            }

            let probes = await Self.runOnIOQueue {
                RuleCatalog.buildProbes(
                    scanner: self,
                    fdaStatus: fdaStatus,
                    runningApps: runningApps,
                    unityProjects: unityProjects,
                    sizeCache: sizeCache,
                    cancelFlag: cancelFlag
                )
            }

            let phase0 = probes.filter { $0.phase == .fastCleanable }
            let phase1 = probes.filter { $0.phase == .spaceInsights }
            let totalProbes = probes.count
            let maxConcurrency = min(12, max(6, ProcessInfo.processInfo.activeProcessorCount))

            var collected: [ScanItem] = []
            var completed = 0

            for batchProbes in [phase0, phase1] where !batchProbes.isEmpty {
                if Task.isCancelled {
                    cancelFlag.cancel()
                    break
                }

                await withTaskGroup(of: (String, [ScanItem]).self) { group in
                    var iterator = batchProbes.makeIterator()

                    for _ in 0..<min(maxConcurrency, batchProbes.count) {
                        if let probe = iterator.next() {
                            group.addTask {
                                if Task.isCancelled { return (probe.label, []) }
                                let result = await Self.runOnIOQueue {
                                    probe.run()
                                }
                                return (probe.label, result)
                            }
                        }
                    }

                    while let (label, items) = await group.next() {
                        if Task.isCancelled {
                            cancelFlag.cancel()
                            group.cancelAll()
                            break
                        }
                        completed += 1
                        onProgress("扫描中 (\(completed)/\(totalProbes))：\(label)")
                        if !items.isEmpty {
                            collected.append(contentsOf: items)
                            onBatch?(items)
                        }

                        if let nextProbe = iterator.next() {
                            group.addTask {
                                if Task.isCancelled { return (nextProbe.label, []) }
                                let result = await Self.runOnIOQueue {
                                    nextProbe.run()
                                }
                                return (nextProbe.label, result)
                            }
                        }
                    }
                }
            }

            let uniqueItems = Self.deduplicateAndSort(collected)
            let elapsed = Date().timeIntervalSince(start)
            return ScanResult(
                volumeStats: volumeStats,
                fdaStatus: fdaStatus,
                items: uniqueItems,
                durationSeconds: elapsed
            )
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    public func refreshTargets(
        existingItems: [ScanItem],
        affectedPaths: [URL],
        includeTrash: Bool,
        fdaStatus: FDAStatus,
        sizeCache: DirectorySizeCache?
    ) async -> (volumeStats: VolumeStats, items: [ScanItem]) {
        await Self.runOnIOQueue {
            let trashURL = self.homeDirectory.appendingPathComponent(".Trash").standardizedFileURL
            let normalizedAffected = affectedPaths.map { Self.normalizePath($0.standardizedFileURL.path) }

            for path in normalizedAffected {
                sizeCache?.invalidate(prefixPath: path)
            }
            if includeTrash {
                sizeCache?.invalidate(prefixPath: trashURL.path)
            }

            let fm = FileManager.default
            var updated: [ScanItem] = []
            updated.reserveCapacity(existingItems.count)

            for item in existingItems {
                if item.id == "tier3.trash" && includeTrash {
                    continue
                }

                let overlaps = item.targets.contains { target in
                    let tPath = Self.normalizePath(target.standardizedFileURL.path)
                    return normalizedAffected.contains { aPath in
                        tPath == aPath || tPath.hasPrefix(aPath + "/") || aPath.hasPrefix(tPath + "/")
                    }
                }

                guard overlaps else {
                    updated.append(item)
                    continue
                }

                if item.id == "tier1.conda.archives" {
                    let archives = Self.filterCondaArchives(in: self.minicondaPkgsDirectory)
                    guard !archives.isEmpty else { continue }
                    let total = archives.reduce(Int64(0)) { acc, url in
                        let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                        return acc + Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0)
                    }
                    guard total >= RuleCatalog.minimumThresholdBytes else { continue }
                    updated.append(ScanItem(
                        id: item.id,
                        title: "Conda 压缩包缓存 (\(archives.count) 个归档)",
                        subtitle: item.subtitle,
                        categoryIcon: item.categoryIcon,
                        tier: item.tier,
                        cleanupMode: item.cleanupMode,
                        allowedRoot: item.allowedRoot,
                        targets: archives,
                        displayPathURL: item.displayPathURL,
                        sizeBytes: total,
                        lastModified: item.lastModified,
                        lockReason: item.lockReason,
                        runningAppWarning: item.runningAppWarning,
                        guidance: item.guidance,
                        isWorktreeException: item.isWorktreeException
                    ))
                    continue
                }

                let existingTargets = item.targets.filter { fm.fileExists(atPath: $0.path) }
                guard !existingTargets.isEmpty else { continue }

                let newSize = existingTargets.reduce(Int64(0)) { acc, target in
                    acc + Self.directorySize(at: target, cache: sizeCache, cacheDepth: 3)
                }

                let threshold = Self.minimumSizeThreshold(for: item)
                guard newSize >= threshold else { continue }

                var updatedSubtitle = item.subtitle
                if item.id.hasPrefix("tier3.home."), let dir = existingTargets.first {
                    let name = dir.lastPathComponent
                    let isBackup = name.localizedCaseInsensitiveContains("backup")
                    var notes: [String] = []
                    if isBackup { notes.append("疑似历史备份目录") }
                    let gitDir = dir.appendingPathComponent(".git")
                    if fm.fileExists(atPath: gitDir.path) {
                        let gitSize = sizeCache?.size(for: gitDir) ?? Self.directorySize(at: gitDir, cache: sizeCache, cacheDepth: 2)
                        notes.append(".git 占 \(DiskByteFormatter.string(from: gitSize))")
                    }
                    let assetsDir = dir.appendingPathComponent("Assets")
                    let settingsDir = dir.appendingPathComponent("ProjectSettings")
                    let unityLib = dir.appendingPathComponent("Library")
                    if fm.fileExists(atPath: assetsDir.path),
                       fm.fileExists(atPath: settingsDir.path),
                       fm.fileExists(atPath: unityLib.path) {
                        let libSize = sizeCache?.size(for: unityLib) ?? Self.directorySize(at: unityLib, cache: sizeCache, cacheDepth: 2)
                        notes.append("Unity Library 占 \(DiskByteFormatter.string(from: libSize))")
                    }
                    updatedSubtitle = notes.isEmpty ? "主目录大文件夹（仅查看，保护你的代码与资料）" : notes.joined(separator: " · ")
                }

                let updatedDisplayURL = fm.fileExists(atPath: item.displayPathURL.path)
                    ? item.displayPathURL
                    : (existingTargets.first ?? item.allowedRoot)

                updated.append(ScanItem(
                    id: item.id,
                    title: item.title,
                    subtitle: updatedSubtitle,
                    categoryIcon: item.categoryIcon,
                    tier: item.tier,
                    cleanupMode: item.cleanupMode,
                    allowedRoot: item.allowedRoot,
                    targets: existingTargets,
                    displayPathURL: updatedDisplayURL,
                    sizeBytes: newSize,
                    lastModified: existingTargets.first.flatMap { Self.modificationDate(at: $0) } ?? item.lastModified,
                    lockReason: item.lockReason,
                    runningAppWarning: item.runningAppWarning,
                    guidance: item.guidance,
                    isWorktreeException: item.isWorktreeException
                ))
            }

            if includeTrash, case .granted = fdaStatus, fm.fileExists(atPath: trashURL.path) {
                let trashSize = Self.directorySize(at: trashURL, cache: sizeCache, cacheDepth: 3)
                if trashSize >= RuleCatalog.minimumThresholdBytes {
                    updated.append(ScanItem(
                        id: "tier3.trash",
                        title: "废纸篓当前占用",
                        subtitle: "已删除但尚未清倒的文件仍占用磁盘空间",
                        categoryIcon: "trash",
                        tier: .readOnly,
                        cleanupMode: .readOnly,
                        allowedRoot: self.homeDirectory,
                        targets: [trashURL],
                        sizeBytes: trashSize,
                        guidance: "点击底部「打开废纸篓」并在 Finder 确认清倒后即可释放空间"
                    ))
                }
            }

            let sorted = Self.deduplicateAndSort(updated)
            return (Self.readVolumeStats(), sorted)
        }
    }

    public static func deduplicateAndSort(_ items: [ScanItem]) -> [ScanItem] {
        var seenIDs = Set<String>()
        var uniqueItems: [ScanItem] = []
        uniqueItems.reserveCapacity(items.count)
        for item in items {
            if seenIDs.insert(item.id).inserted {
                uniqueItems.append(item)
            }
        }

        let tierOrder: [RiskTier: Int] = [.safe: 0, .caution: 1, .readOnly: 2]
        uniqueItems.sort { lhs, rhs in
            let lOrder = tierOrder[lhs.tier] ?? 9
            let rOrder = tierOrder[rhs.tier] ?? 9
            if lOrder != rOrder { return lOrder < rOrder }
            return lhs.sizeBytes > rhs.sizeBytes
        }
        return uniqueItems
    }

    private static func normalizePath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func minimumSizeThreshold(for item: ScanItem) -> Int64 {
        if item.id.hasPrefix("tier1.cache.other.") {
            return 20_000_000
        }
        if item.tier == .safe || item.tier == .caution {
            return RuleCatalog.minimumThresholdBytes
        }
        if item.id == "tier3.trash" {
            return RuleCatalog.minimumThresholdBytes
        }
        if item.id.hasPrefix("tier3.app.") || item.id.hasPrefix("tier3.appsupport.") {
            return 500_000_000
        }
        if item.id.hasPrefix("tier3.home.") {
            let isBackup = item.displayPathURL.lastPathComponent.localizedCaseInsensitiveContains("backup")
            return isBackup ? 50_000_000 : 1_000_000_000
        }
        if item.sizeBytes == 0 {
            return 0
        }
        return 100_000_000
    }
}
