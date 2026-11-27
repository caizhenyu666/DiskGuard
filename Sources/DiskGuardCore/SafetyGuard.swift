import Foundation
import Darwin

public enum GuardRejection: Error, Equatable, Sendable, CustomStringConvertible {
    case readOnlyTier
    case lockedItem(String)
    case symbolicLinkRejected(String)
    case outsideAllowedRoot(target: String, root: String)
    case protectedPath(String)
    case containsGitRepository(String)
    case targetEqualsProtectedContainer(String)
    case doesNotExist(String)
    case outsideTrash(String)

    public var description: String {
        switch self {
        case .readOnlyTier:
            return "只读项目禁止清理"
        case .lockedItem(let reason):
            return "条目已锁定（\(reason)），禁止清理"
        case .symbolicLinkRejected(let path):
            return "出于安全限制，拒绝跟进符号链接：\(path)"
        case .outsideAllowedRoot(let target, let root):
            return "目标路径超出允许范围（\(target) 不在 \(root) 内）"
        case .protectedPath(let path):
            return "命中受保护路径黑名单，拒绝操作：\(path)"
        case .containsGitRepository(let path):
            return "检测到 Git 仓库目录（.git），禁止清理：\(path)"
        case .targetEqualsProtectedContainer(let path):
            return "禁止直接删除共享根容器目录：\(path)"
        case .doesNotExist(let path):
            return "目标路径不存在：\(path)"
        case .outsideTrash(let path):
            return "出于安全限制，彻底清除仅允许操作废纸篓内的项目：\(path)"
        }
    }
}

public struct SafetyGuard: Sendable {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    private var canonicalHome: URL {
        homeDirectory.resolvingSymlinksInPath().standardizedFileURL
    }

    private var sharedContainerRoots: Set<String> {
        let home = canonicalHome
        return Set([
            home.path,
            home.appendingPathComponent("Library/Caches").resolvingSymlinksInPath().standardizedFileURL.path,
            home.appendingPathComponent("Library/Logs").resolvingSymlinksInPath().standardizedFileURL.path,
            home.appendingPathComponent(".codex/worktrees").resolvingSymlinksInPath().standardizedFileURL.path,
            home.appendingPathComponent("Downloads").resolvingSymlinksInPath().standardizedFileURL.path,
            URL(fileURLWithPath: "/opt/miniconda3/pkgs").resolvingSymlinksInPath().standardizedFileURL.path
        ])
    }

    private var protectedExactPaths: Set<String> {
        let home = canonicalHome
        return Set([
            "/",
            "/System",
            "/Applications",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/var",
            "/private/var",
            "/var/db",
            "/private/var/db",
            home.path
        ])
    }

    private var protectedSubtrees: [String] {
        let home = canonicalHome
        let rawPaths = [
            "/System",
            "/Applications",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/private/etc",
            "/var/db",
            "/private/var/db",
            home.appendingPathComponent("Desktop").path,
            home.appendingPathComponent("Documents").path,
            home.appendingPathComponent("Pictures").path,
            home.appendingPathComponent("Movies").path,
            home.appendingPathComponent("Music").path,
            home.appendingPathComponent(".ssh").path,
            home.appendingPathComponent(".gnupg").path,
            home.appendingPathComponent("Library/Keychains").path,
            home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat").path,
            home.appendingPathComponent("Library/Containers/5ZSL2CJU2T.com.dingtalk.mac").path
        ]
        return rawPaths.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        }
    }

    private static func lstatMode(atPath path: String) -> mode_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return nil
        }
        return st.st_mode & S_IFMT
    }

    @discardableResult
    public func validate(
        target: URL,
        allowedRoot: URL,
        tier: RiskTier,
        cleanupMode: CleanupMode,
        lockReason: String?,
        allowWorktreePointer: Bool
    ) throws -> URL {
        if tier == .readOnly || cleanupMode == .readOnly {
            throw GuardRejection.readOnlyTier
        }
        if let lockReason, !lockReason.isEmpty {
            throw GuardRejection.lockedItem(lockReason)
        }

        let standardizedTarget = target.standardizedFileURL
        guard let targetMode = Self.lstatMode(atPath: standardizedTarget.path) else {
            throw GuardRejection.doesNotExist(standardizedTarget.path)
        }
        if targetMode == S_IFLNK {
            throw GuardRejection.symbolicLinkRejected(standardizedTarget.path)
        }

        let canonicalTarget = standardizedTarget.resolvingSymlinksInPath().standardizedFileURL
        let canonicalRoot = allowedRoot.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL

        let targetPath = canonicalTarget.path
        let rootPath = canonicalRoot.path

        if cleanupMode == .trashChildren {
            let insideOrEqual = (targetPath == rootPath) || targetPath.hasPrefix(rootPath + "/")
            guard insideOrEqual else {
                throw GuardRejection.outsideAllowedRoot(target: targetPath, root: rootPath)
            }
        } else {
            guard targetPath.hasPrefix(rootPath + "/") else {
                throw GuardRejection.outsideAllowedRoot(target: targetPath, root: rootPath)
            }
        }

        if targetPath == rootPath && sharedContainerRoots.contains(rootPath) {
            throw GuardRejection.targetEqualsProtectedContainer(targetPath)
        }

        if protectedExactPaths.contains(targetPath) {
            throw GuardRejection.protectedPath(targetPath)
        }

        for subtree in protectedSubtrees {
            if targetPath == subtree || targetPath.hasPrefix(subtree + "/") {
                throw GuardRejection.protectedPath(targetPath)
            }
        }

        if canonicalTarget.pathComponents.contains(".git") {
            throw GuardRejection.protectedPath(targetPath)
        }

        if targetMode == S_IFDIR {
            let dotGitURL = canonicalTarget.appendingPathComponent(".git")
            if let gitMode = Self.lstatMode(atPath: dotGitURL.path) {
                if gitMode == S_IFDIR {
                    throw GuardRejection.containsGitRepository(targetPath)
                }
                if gitMode == S_IFREG {
                    let worktreesRoot = canonicalHome
                        .appendingPathComponent(".codex/worktrees")
                        .resolvingSymlinksInPath()
                        .standardizedFileURL
                        .path
                    let isCodexWorktree = allowWorktreePointer && targetPath.hasPrefix(worktreesRoot + "/")
                    if !isCodexWorktree {
                        throw GuardRejection.containsGitRepository(targetPath)
                    }
                } else {
                    throw GuardRejection.containsGitRepository(targetPath)
                }
            }
        }

        return canonicalTarget
    }

    public static func defaultSizeBytes(at url: URL) -> Int64 {
        if lstatMode(atPath: url.path) == S_IFLNK {
            return 0
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0)
        }
        return DiskScanner.directorySize(at: url)
    }

    public func trash(
        item: ScanItem,
        sizeEstimator: (URL) -> Int64 = { SafetyGuard.defaultSizeBytes(at: $0) },
        trashHandler: (URL) throws -> URL? = { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return resultingURL as URL?
        }
    ) -> CleanItemReport {
        var logs: [LogEntry] = []
        var trashedCount = 0
        var skippedCount = 0
        var reclaimedBytes: Int64 = 0

        if item.tier == .readOnly || item.cleanupMode == .readOnly {
            logs.append(LogEntry(level: .error, message: "拒绝清理只读项目：\(item.title)"))
            return CleanItemReport(itemTitle: item.title, trashedCount: 0, skippedCount: 1, reclaimedBytes: 0, messages: logs, wasWorktree: false)
        }

        if let lockReason = item.lockReason, !lockReason.isEmpty {
            logs.append(LogEntry(level: .warning, message: "已跳过锁定项目「\(item.title)」：\(lockReason)"))
            return CleanItemReport(itemTitle: item.title, trashedCount: 0, skippedCount: 1, reclaimedBytes: 0, messages: logs, wasWorktree: false)
        }

        let fm = FileManager.default

        switch item.cleanupMode {
        case .readOnly:
            break

        case .trashItem:
            for target in item.targets {
                do {
                    let validURL = try validate(
                        target: target,
                        allowedRoot: item.allowedRoot,
                        tier: item.tier,
                        cleanupMode: .trashItem,
                        lockReason: item.lockReason,
                        allowWorktreePointer: item.isWorktreeException
                    )
                    let bytes = sizeEstimator(validURL)
                    _ = try trashHandler(validURL)
                    trashedCount += 1
                    reclaimedBytes += bytes
                    logs.append(LogEntry(
                        level: .success,
                        message: "已移入废纸篓：\(DiskByteFormatter.compactPath(validURL, home: homeDirectory))（\(DiskByteFormatter.string(from: bytes))）"
                    ))
                } catch let rejection as GuardRejection {
                    skippedCount += 1
                    logs.append(LogEntry(level: .warning, message: "安全拦截「\(item.title)」：\(rejection.description)"))
                } catch {
                    skippedCount += 1
                    logs.append(LogEntry(level: .warning, message: "已跳过「\(target.lastPathComponent)」：\(error.localizedDescription)"))
                }
            }

        case .trashChildren:
            for container in item.targets {
                do {
                    let validContainer = try validate(
                        target: container,
                        allowedRoot: item.allowedRoot,
                        tier: item.tier,
                        cleanupMode: .trashChildren,
                        lockReason: item.lockReason,
                        allowWorktreePointer: false
                    )
                    let children = try fm.contentsOfDirectory(
                        at: validContainer,
                        includingPropertiesForKeys: [.isSymbolicLinkKey],
                        options: []
                    )
                    for child in children {
                        do {
                            let validChild = try validate(
                                target: child,
                                allowedRoot: item.allowedRoot,
                                tier: item.tier,
                                cleanupMode: .trashItem,
                                lockReason: item.lockReason,
                                allowWorktreePointer: false
                            )
                            let bytes = sizeEstimator(validChild)
                            _ = try trashHandler(validChild)
                            trashedCount += 1
                            reclaimedBytes += bytes
                        } catch let rejection as GuardRejection {
                            skippedCount += 1
                            logs.append(LogEntry(level: .warning, message: "安全跳过子项：\(rejection.description)"))
                        } catch {
                            skippedCount += 1
                            logs.append(LogEntry(level: .warning, message: "跳过被占用或无权限子项「\(child.lastPathComponent)」：\(error.localizedDescription)"))
                        }
                    }
                    if trashedCount > 0 {
                        logs.append(LogEntry(
                            level: .success,
                            message: "已清理「\(item.title)」共 \(trashedCount) 个子项至废纸篓（\(DiskByteFormatter.string(from: reclaimedBytes))）"
                        ))
                    } else if skippedCount == 0 {
                        logs.append(LogEntry(level: .info, message: "「\(item.title)」目录为空，无需清理"))
                    }
                } catch let rejection as GuardRejection {
                    skippedCount += 1
                    logs.append(LogEntry(level: .warning, message: "安全拦截「\(item.title)」：\(rejection.description)"))
                } catch {
                    skippedCount += 1
                    logs.append(LogEntry(level: .warning, message: "无法读取「\(item.title)」：\(error.localizedDescription)"))
                }
            }
        }

        if item.isWorktreeException && trashedCount > 0 {
            logs.append(LogEntry(
                level: .info,
                message: "提示：已将 Codex worktree 移入废纸篓，可按需在主仓库运行 git worktree prune 清理引用"
            ))
        }

        return CleanItemReport(
            itemTitle: item.title,
            trashedCount: trashedCount,
            skippedCount: skippedCount,
            reclaimedBytes: reclaimedBytes,
            messages: logs,
            wasWorktree: item.isWorktreeException
        )
    }

    public func validateTrashDeletion(target: URL) throws -> URL {
        let canonicalTrash = canonicalHome
            .appendingPathComponent(".Trash")
            .resolvingSymlinksInPath()
            .standardizedFileURL

        let standardizedTarget = target.standardizedFileURL
        guard Self.lstatMode(atPath: standardizedTarget.path) != nil else {
            throw GuardRejection.doesNotExist(standardizedTarget.path)
        }

        let name = standardizedTarget.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw GuardRejection.outsideTrash(standardizedTarget.path)
        }

        let canonicalParent = standardizedTarget
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL

        let parentPath = canonicalParent.path
        let trashPath = canonicalTrash.path
        guard parentPath == trashPath || parentPath.hasPrefix(trashPath + "/") else {
            throw GuardRejection.outsideTrash(standardizedTarget.path)
        }

        let safeTarget = canonicalParent.appendingPathComponent(name)
        guard safeTarget.path != trashPath else {
            throw GuardRejection.targetEqualsProtectedContainer(safeTarget.path)
        }

        return safeTarget
    }

    public func permanentlyDeleteFromTrash(
        targets: [URL],
        sizeEstimator: (URL) -> Int64 = { SafetyGuard.defaultSizeBytes(at: $0) },
        removeHandler: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> CleanItemReport {
        var logs: [LogEntry] = []
        var deletedCount = 0
        var skippedCount = 0
        var reclaimedBytes: Int64 = 0

        for target in targets {
            do {
                let validTarget = try validateTrashDeletion(target: target)
                let bytes = Self.lstatMode(atPath: validTarget.path) == S_IFLNK ? 0 : sizeEstimator(validTarget)
                try removeHandler(validTarget)
                deletedCount += 1
                reclaimedBytes += bytes
                logs.append(LogEntry(
                    level: .success,
                    message: "已从废纸篓彻底清除：\(validTarget.lastPathComponent)（\(DiskByteFormatter.string(from: bytes))）"
                ))
            } catch let rejection as GuardRejection {
                skippedCount += 1
                logs.append(LogEntry(level: .warning, message: "废纸篓安全拦截：\(rejection.description)"))
            } catch {
                skippedCount += 1
                logs.append(LogEntry(level: .warning, message: "无法清除「\(target.lastPathComponent)」：\(error.localizedDescription)"))
            }
        }

        return CleanItemReport(
            itemTitle: "废纸篓彻底清除",
            trashedCount: deletedCount,
            skippedCount: skippedCount,
            reclaimedBytes: reclaimedBytes,
            messages: logs,
            wasWorktree: false
        )
    }

    public func emptyTrash(
        sizeEstimator: (URL) -> Int64 = { SafetyGuard.defaultSizeBytes(at: $0) },
        removeHandler: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> CleanItemReport {
        let trashURL = canonicalHome.appendingPathComponent(".Trash")
        guard FileManager.default.fileExists(atPath: trashURL.path) else {
            return CleanItemReport(
                itemTitle: "清空废纸篓",
                trashedCount: 0,
                skippedCount: 0,
                reclaimedBytes: 0,
                messages: [LogEntry(level: .info, message: "废纸篓为空")],
                wasWorktree: false
            )
        }

        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: trashURL,
                includingPropertiesForKeys: nil,
                options: []
            ).filter { url in
                let name = url.lastPathComponent
                return name != ".DS_Store" && name != ".localized"
            }

            if children.isEmpty {
                return CleanItemReport(
                    itemTitle: "清空废纸篓",
                    trashedCount: 0,
                    skippedCount: 0,
                    reclaimedBytes: 0,
                    messages: [LogEntry(level: .info, message: "废纸篓已为空，无需清理")],
                    wasWorktree: false
                )
            }

            return permanentlyDeleteFromTrash(
                targets: children,
                sizeEstimator: sizeEstimator,
                removeHandler: removeHandler
            )
        } catch {
            return CleanItemReport(
                itemTitle: "清空废纸篓",
                trashedCount: 0,
                skippedCount: 1,
                reclaimedBytes: 0,
                messages: [LogEntry(level: .error, message: "无法读取废纸篓：\(error.localizedDescription)")],
                wasWorktree: false
            )
        }
    }
}
