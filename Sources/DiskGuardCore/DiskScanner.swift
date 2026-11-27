import Foundation
import AppKit

public final class DiskScanner: Sendable {
    public let homeDirectory: URL
    public let applicationsDirectory: URL
    public let systemLibraryDirectory: URL
    public let minicondaPkgsDirectory: URL

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
        let fm = FileManager.default
        let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if vals?.isSymbolicLink == true {
            return 0
        }
        if vals?.isDirectory == false {
            return Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0)
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileResourceIdentifierKey
        ]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else {
            return 0
        }

        var seenInodes = Set<Data>()
        var total: Int64 = 0

        for case let itemURL as URL in enumerator {
            guard let itemVals = try? itemURL.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            if itemVals.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard itemVals.isRegularFile == true else {
                continue
            }
            if let identifier = itemVals.fileResourceIdentifier as? Data {
                if !seenInodes.insert(identifier).inserted {
                    continue
                }
            }
            total += Int64(itemVals.totalFileAllocatedSize ?? itemVals.fileAllocatedSize ?? 0)
        }
        return total
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

    public func scanAll(onProgress: @escaping @Sendable (String) -> Void) async -> ScanResult {
        let start = Date()
        onProgress("正在读取磁盘容量与系统权限...")

        let volumeStats = Self.readVolumeStats()
        let fdaStatus = Self.checkFullDiskAccess(home: homeDirectory)
        let runningApps = Self.runningAppNames()
        let unityProjects = Self.discoverUnityProjects(in: homeDirectory)

        let probes = RuleCatalog.buildProbes(
            scanner: self,
            fdaStatus: fdaStatus,
            runningApps: runningApps,
            unityProjects: unityProjects
        )

        var collected: [ScanItem] = []
        let totalProbes = probes.count
        var completed = 0

        await withTaskGroup(of: (String, [ScanItem]).self) { group in
            let maxConcurrency = 6
            var iterator = probes.makeIterator()

            for _ in 0..<min(maxConcurrency, totalProbes) {
                if let probe = iterator.next() {
                    group.addTask {
                        if Task.isCancelled { return (probe.label, []) }
                        return (probe.label, probe.run())
                    }
                }
            }

            while let (label, items) = await group.next() {
                if Task.isCancelled { break }
                completed += 1
                onProgress("扫描中 (\(completed)/\(totalProbes))：\(label)")
                collected.append(contentsOf: items)

                if let nextProbe = iterator.next() {
                    group.addTask {
                        if Task.isCancelled { return (nextProbe.label, []) }
                        return (nextProbe.label, nextProbe.run())
                    }
                }
            }
        }

        // Deduplicate by id just in case, keeping highest priority entry
        var seenIDs = Set<String>()
        var uniqueItems: [ScanItem] = []
        for item in collected {
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

        let elapsed = Date().timeIntervalSince(start)
        return ScanResult(
            volumeStats: volumeStats,
            fdaStatus: fdaStatus,
            items: uniqueItems,
            durationSeconds: elapsed
        )
    }
}
