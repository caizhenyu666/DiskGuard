import Foundation

public enum ScanPhase: Int, Sendable {
    case fastCleanable = 0
    case spaceInsights = 1
}

public struct ScanProbe: Sendable {
    public let label: String
    public let phase: ScanPhase
    public let run: @Sendable () -> [ScanItem]

    public init(
        label: String,
        phase: ScanPhase = .fastCleanable,
        run: @escaping @Sendable () -> [ScanItem]
    ) {
        self.label = label
        self.phase = phase
        self.run = run
    }
}

public enum RuleCatalog {
    public static let minimumThresholdBytes: Int64 = 1_000_000 // 1 MB

    private static func runningWarning(for keywords: [String], runningApps: Set<String>, appDisplayName: String) -> String? {
        for app in runningApps {
            for kw in keywords where app.contains(kw) {
                return "\(appDisplayName) 运行中"
            }
        }
        return nil
    }

    private static func readBundleVersion(appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) else { return nil }
        return (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String)
    }

    public static func buildProbes(
        scanner: DiskScanner,
        fdaStatus: FDAStatus,
        runningApps: Set<String>,
        unityProjects: [URL],
        sizeCache: DirectorySizeCache? = nil,
        cancelFlag: AtomicCancelFlag? = nil
    ) -> [ScanProbe] {
        let home = scanner.homeDirectory
        let appsDir = scanner.applicationsDirectory
        let sysLib = scanner.systemLibraryDirectory
        let condaPkgs = scanner.minicondaPkgsDirectory
        let hasFDA: Bool = {
            if case .granted = fdaStatus { return true }
            return false
        }()

        var probes: [ScanProbe] = []
        let fm = FileManager.default

        // MARK: - Phase 0 (Fast Cleanable): ~/Library/Caches
        let cachesRoot = home.appendingPathComponent("Library/Caches")
        let knownSpecs: [(folder: String, title: String, desc: String, icon: String, keywords: [String], appName: String)] = [
            ("Google", "Google / Chrome 缓存", "浏览器网页与组件缓存，清理后可自动重建", "globe", ["google chrome"], "Chrome"),
            ("JetBrains", "JetBrains IDE 缓存", "Rider / IDEA 等本地索引与构建缓存，重开后重建", "hammer", ["rider", "jetbrains", "intellij"], "JetBrains IDE"),
            ("com.openai.codex", "Codex 桌面缓存", "Codex 客户端缓存数据，可重建", "sparkles", ["codex"], "Codex"),
            ("Codex", "Codex 辅助缓存", "Codex 运行缓存，可重建", "sparkles", ["codex"], "Codex"),
            ("Homebrew", "Homebrew 下载缓存", "brew 安装包归档缓存，可随时重新下载", "shippingbox", [], ""),
            ("com.tencent.workbuddy.mac.BundleMigration", "WorkBuddy 迁移缓存", "客户端升级迁移临时缓存，可安全清理", "arrow.triangle.2.circlepath", ["workbuddy"], "WorkBuddy"),
            ("com.qoder.ide.ShipIt", "Qoder 更新缓存", "Qoder 自动更新安装包缓存", "arrow.down.circle", ["qoder"], "Qoder"),
            ("qoder-updater", "Qoder Updater 缓存", "Qoder 更新器临时下载文件", "arrow.down.circle", ["qoder"], "Qoder"),
            ("com.google.antigravity", "Antigravity 缓存", "Antigravity 应用缓存，可重建", "cpu", ["antigravity"], "Antigravity"),
            ("pip", "pip 包下载缓存", "Python pip 下载包缓存，按需重新拉取", "cube.box", [], "")
        ]
        let knownNames = Set(knownSpecs.map { $0.folder })

        for spec in knownSpecs {
            let target = cachesRoot.appendingPathComponent(spec.folder)
            guard fm.fileExists(atPath: target.path) else { continue }
            let warn = spec.keywords.isEmpty ? nil : runningWarning(for: spec.keywords, runningApps: runningApps, appDisplayName: spec.appName)
            probes.append(ScanProbe(label: spec.title, phase: .fastCleanable) {
                let size = DiskScanner.directorySize(at: target, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= minimumThresholdBytes else { return [] }
                return [ScanItem(
                    id: "tier1.cache.\(spec.folder)",
                    title: spec.title,
                    subtitle: spec.desc,
                    categoryIcon: spec.icon,
                    tier: .safe,
                    cleanupMode: .trashChildren,
                    allowedRoot: cachesRoot,
                    targets: [target],
                    sizeBytes: size,
                    lastModified: DiskScanner.modificationDate(at: target),
                    runningAppWarning: warn
                )]
            })
        }

        if let others = try? fm.contentsOfDirectory(
            at: cachesRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in others {
                let name = dir.lastPathComponent
                if knownNames.contains(name) || name.hasPrefix("com.apple.") || name == "GeoServices" {
                    continue
                }
                let vals = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard vals?.isSymbolicLink != true, vals?.isDirectory == true else { continue }
                probes.append(ScanProbe(label: "缓存：\(name)", phase: .fastCleanable) {
                    let size = DiskScanner.directorySize(at: dir, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    guard size >= 20_000_000 else { return [] }
                    return [ScanItem(
                        id: "tier1.cache.other.\(name)",
                        title: "第三方应用缓存：\(name)",
                        subtitle: "第三方应用可重建缓存",
                        categoryIcon: "folder.badge.gearshape",
                        tier: .safe,
                        cleanupMode: .trashChildren,
                        allowedRoot: cachesRoot,
                        targets: [dir],
                        sizeBytes: size,
                        lastModified: DiskScanner.modificationDate(at: dir)
                    )]
                })
            }
        }

        // MARK: - Phase 0 (Fast Cleanable): Xcode, Unity/Tuanjie, Package Managers
        let xcodeRoot = home.appendingPathComponent("Library/Developer/Xcode")
        let xcodeWarn = runningWarning(for: ["xcode"], runningApps: runningApps, appDisplayName: "Xcode")

        let previews = xcodeRoot.appendingPathComponent("UserData/Previews")
        if fm.fileExists(atPath: previews.path) {
            probes.append(ScanProbe(label: "Xcode Previews 缓存", phase: .fastCleanable) {
                let size = DiskScanner.directorySize(at: previews, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= minimumThresholdBytes else { return [] }
                return [ScanItem(
                    id: "tier1.xcode.previews",
                    title: "Xcode Previews 缓存",
                    subtitle: "SwiftUI 画布预览容器缓存，可重新生成",
                    categoryIcon: "hammer.circle",
                    tier: .safe,
                    cleanupMode: .trashItem,
                    allowedRoot: xcodeRoot.appendingPathComponent("UserData"),
                    targets: [previews],
                    sizeBytes: size,
                    runningAppWarning: xcodeWarn
                )]
            })
        }

        let derived = xcodeRoot.appendingPathComponent("DerivedData")
        if fm.fileExists(atPath: derived.path) {
            probes.append(ScanProbe(label: "Xcode DerivedData", phase: .fastCleanable) {
                let size = DiskScanner.directorySize(at: derived, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= minimumThresholdBytes else { return [] }
                return [ScanItem(
                    id: "tier1.xcode.deriveddata",
                    title: "Xcode DerivedData",
                    subtitle: "Xcode 编译中间产物与索引，重编自动生成",
                    categoryIcon: "wrench.and.screwdriver",
                    tier: .safe,
                    cleanupMode: .trashItem,
                    allowedRoot: xcodeRoot,
                    targets: [derived],
                    sizeBytes: size,
                    runningAppWarning: xcodeWarn
                )]
            })
        }

        let unityCache = home.appendingPathComponent("Library/Unity/cache")
        if fm.fileExists(atPath: unityCache.path) {
            let unityWarn = runningWarning(for: ["unity"], runningApps: runningApps, appDisplayName: "Unity")
            probes.append(ScanProbe(label: "Unity 包与 npm 缓存", phase: .fastCleanable) {
                let size = DiskScanner.directorySize(at: unityCache, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= minimumThresholdBytes else { return [] }
                return [ScanItem(
                    id: "tier1.unity.cache",
                    title: "Unity 包与 npm 缓存",
                    subtitle: "Unity Package Manager 下载缓存，按需重新下载",
                    categoryIcon: "cube.transparent",
                    tier: .safe,
                    cleanupMode: .trashChildren,
                    allowedRoot: home.appendingPathComponent("Library/Unity"),
                    targets: [unityCache],
                    sizeBytes: size,
                    runningAppWarning: unityWarn
                )]
            })
        }

        let tuanjieCache = home.appendingPathComponent("Library/Tuanjie/cache")
        if fm.fileExists(atPath: tuanjieCache.path) {
            let tuanjieWarn = runningWarning(for: ["tuanjie"], runningApps: runningApps, appDisplayName: "团结引擎")
            probes.append(ScanProbe(label: "团结引擎包与 npm 缓存", phase: .fastCleanable) {
                let size = DiskScanner.directorySize(at: tuanjieCache, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= minimumThresholdBytes else { return [] }
                return [ScanItem(
                    id: "tier1.tuanjie.cache",
                    title: "团结引擎包与 npm 缓存",
                    subtitle: "Tuanjie Package Manager 缓存，按需重新下载",
                    categoryIcon: "cube.transparent",
                    tier: .safe,
                    cleanupMode: .trashChildren,
                    allowedRoot: home.appendingPathComponent("Library/Tuanjie"),
                    targets: [tuanjieCache],
                    sizeBytes: size,
                    runningAppWarning: tuanjieWarn
                )]
            })
        }

        let npmRoot = home.appendingPathComponent(".npm")
        for sub in ["_cacache", "_npx"] {
            let target = npmRoot.appendingPathComponent(sub)
            if fm.fileExists(atPath: target.path) {
                probes.append(ScanProbe(label: "npm 缓存 (\(sub))", phase: .fastCleanable) {
                    let size = DiskScanner.directorySize(at: target, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    guard size >= minimumThresholdBytes else { return [] }
                    return [ScanItem(
                        id: "tier1.npm.\(sub)",
                        title: "npm 缓存 (\(sub))",
                        subtitle: "Node.js 包与 npx 临时下载缓存，可重建",
                        categoryIcon: "shippingbox.circle",
                        tier: .safe,
                        cleanupMode: .trashChildren,
                        allowedRoot: npmRoot,
                        targets: [target],
                        sizeBytes: size
                    )]
                })
            }
        }

        let uvCache = home.appendingPathComponent(".cache/uv")
        if fm.fileExists(atPath: uvCache.path) {
            probes.append(ScanProbe(label: "uv (Python) 包缓存", phase: .fastCleanable) {
                let size = DiskScanner.directorySize(at: uvCache, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= minimumThresholdBytes else { return [] }
                return [ScanItem(
                    id: "tier1.uv.cache",
                    title: "uv (Python) 包缓存",
                    subtitle: "Python uv 下载与构建归档缓存，按需重下",
                    categoryIcon: "shippingbox",
                    tier: .safe,
                    cleanupMode: .trashChildren,
                    allowedRoot: home.appendingPathComponent(".cache"),
                    targets: [uvCache],
                    sizeBytes: size
                )]
            })
        }

        if fm.fileExists(atPath: condaPkgs.path) {
            probes.append(ScanProbe(label: "Conda 压缩包缓存", phase: .fastCleanable) {
                let archives = DiskScanner.filterCondaArchives(in: condaPkgs)
                guard !archives.isEmpty else { return [] }
                let total = archives.reduce(Int64(0)) { acc, url in
                    let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                    return acc + Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0)
                }
                guard total >= minimumThresholdBytes else { return [] }
                return [ScanItem(
                    id: "tier1.conda.archives",
                    title: "Conda 压缩包缓存 (\(archives.count) 个归档)",
                    subtitle: "仅清理 .tar.bz2 / .conda 压缩包，绝不触碰已解压硬链接环境",
                    categoryIcon: "archivebox",
                    tier: .safe,
                    cleanupMode: .trashItem,
                    allowedRoot: condaPkgs,
                    targets: archives,
                    displayPathURL: condaPkgs,
                    sizeBytes: total
                )]
            })
        }

        // MARK: - Phase 0 (Fast Cleanable): Logs & Temp leftovers & Unity Temp
        probes.append(ScanProbe(label: "日志与临时目录", phase: .fastCleanable) {
            var items: [ScanItem] = []
            let logsRoot = home.appendingPathComponent("Library/Logs")
            let logTargets: [(folder: String, title: String)] = [
                ("JetBrains", "JetBrains 运行日志"),
                ("Unity", "Unity 编辑器日志"),
                ("Tuanjie", "团结引擎编辑器日志"),
                ("com.openai.codex", "Codex 运行日志")
            ]
            for lt in logTargets {
                let target = logsRoot.appendingPathComponent(lt.folder)
                guard FileManager.default.fileExists(atPath: target.path) else { continue }
                let size = DiskScanner.directorySize(at: target, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= minimumThresholdBytes else { continue }
                items.append(ScanItem(
                    id: "tier1.logs.\(lt.folder)",
                    title: lt.title,
                    subtitle: "历史诊断与编辑器日志文件，可安全清理",
                    categoryIcon: "doc.text",
                    tier: .safe,
                    cleanupMode: .trashChildren,
                    allowedRoot: logsRoot,
                    targets: [target],
                    sizeBytes: size
                ))
            }

            let codexRuntimes = home.appendingPathComponent(".cache/codex-runtimes")
            if let children = try? FileManager.default.contentsOfDirectory(
                at: codexRuntimes,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) {
                for dir in children where dir.lastPathComponent.hasPrefix("codex-runtime-install-") {
                    let vals = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard vals?.isSymbolicLink != true, vals?.isDirectory == true else { continue }
                    let size = DiskScanner.directorySize(at: dir, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    guard size >= minimumThresholdBytes else { continue }
                    items.append(ScanItem(
                        id: "tier1.codex.install.\(dir.lastPathComponent)",
                        title: "Codex 运行时安装临时目录",
                        subtitle: "安装阶段残留目录（\(dir.lastPathComponent)）",
                        categoryIcon: "trash.slash",
                        tier: .safe,
                        cleanupMode: .trashItem,
                        allowedRoot: codexRuntimes,
                        targets: [dir],
                        sizeBytes: size,
                        lastModified: DiskScanner.modificationDate(at: dir),
                        runningAppWarning: runningWarning(for: ["codex"], runningApps: runningApps, appDisplayName: "Codex")
                    ))
                }
            }

            let workbuddyTmp = home.appendingPathComponent(".workbuddy/tmp")
            if FileManager.default.fileExists(atPath: workbuddyTmp.path) {
                let size = DiskScanner.directorySize(at: workbuddyTmp, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                if size >= minimumThresholdBytes {
                    items.append(ScanItem(
                        id: "tier1.workbuddy.tmp",
                        title: "WorkBuddy 临时目录",
                        subtitle: "WorkBuddy 运行临时文件",
                        categoryIcon: "folder.badge.minus",
                        tier: .safe,
                        cleanupMode: .trashChildren,
                        allowedRoot: home.appendingPathComponent(".workbuddy"),
                        targets: [workbuddyTmp],
                        sizeBytes: size,
                        runningAppWarning: runningWarning(for: ["workbuddy"], runningApps: runningApps, appDisplayName: "WorkBuddy")
                    ))
                }
            }

            if let homeChildren = try? FileManager.default.contentsOfDirectory(
                at: home,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) {
                let openskillsDirs = homeChildren.filter { $0.lastPathComponent.hasPrefix(".openskills-temp-") }
                if !openskillsDirs.isEmpty {
                    let total = openskillsDirs.reduce(Int64(0)) {
                        $0 + DiskScanner.directorySize(at: $1, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    }
                    if total >= minimumThresholdBytes {
                        items.append(ScanItem(
                            id: "tier1.openskills.temp",
                            title: "OpenSkills 临时目录 (\(openskillsDirs.count) 个)",
                            subtitle: "技能安装遗留临时目录，可安全清理",
                            categoryIcon: "folder.badge.minus",
                            tier: .safe,
                            cleanupMode: .trashItem,
                            allowedRoot: home,
                            targets: openskillsDirs,
                            displayPathURL: openskillsDirs.first,
                            sizeBytes: total
                        ))
                    }
                }
            }

            return items
        })

        for project in unityProjects {
            let tempDir = project.appendingPathComponent("Temp")
            if fm.fileExists(atPath: tempDir.path) {
                probes.append(ScanProbe(label: "Unity Temp：\(project.lastPathComponent)", phase: .fastCleanable) {
                    let size = DiskScanner.directorySize(at: tempDir, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    guard size >= minimumThresholdBytes else { return [] }
                    let locked = DiskScanner.isUnityProjectLocked(project)
                    return [ScanItem(
                        id: "tier1.unity.temp.\(project.lastPathComponent)",
                        title: "Unity Temp：\(project.lastPathComponent)",
                        subtitle: locked ? "检测到 UnityLockfile，工程正在编辑器中打开" : "Unity 编辑器临时编译目录，工程关闭时可安全清理",
                        categoryIcon: "cube",
                        tier: .safe,
                        cleanupMode: .trashItem,
                        allowedRoot: project,
                        targets: [tempDir],
                        sizeBytes: size,
                        lastModified: DiskScanner.modificationDate(at: tempDir),
                        lockReason: locked ? "Unity 正在运行此工程" : nil
                    )]
                })
            }
        }

        // MARK: - Phase 0 (Fast Cleanable): Codex Worktrees (per-worktree concurrent probes)
        let worktreesRoot = home.appendingPathComponent(".codex/worktrees")
        if let worktrees = try? fm.contentsOfDirectory(
            at: worktreesRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for wt in worktrees {
                let vals = try? wt.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard vals?.isSymbolicLink != true, vals?.isDirectory == true else { continue }
                let modDate = vals?.contentModificationDate
                probes.append(ScanProbe(label: "Codex worktree：\(wt.lastPathComponent)", phase: .fastCleanable) {
                    let size = DiskScanner.directorySize(at: wt, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    guard size >= minimumThresholdBytes else { return [] }
                    let dirty = DiskScanner.isWorktreeDirty(at: wt)
                    let dateText = modDate.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) } ?? ""
                    return [ScanItem(
                        id: "tier2.codex.worktree.\(wt.lastPathComponent)",
                        title: "Codex worktree：\(wt.lastPathComponent)",
                        subtitle: dirty
                            ? "\(dateText) · 检测到未提交修改，已自动锁定禁止清理"
                            : "\(dateText) · 工作树干净无未提交改动（移入废纸篓后可运行 git worktree prune）",
                        categoryIcon: "arrow.triangle.branch",
                        tier: .caution,
                        cleanupMode: .trashItem,
                        allowedRoot: worktreesRoot,
                        targets: [wt],
                        sizeBytes: size,
                        lastModified: modDate,
                        lockReason: dirty ? "含未提交改动 · 已锁定" : nil,
                        isWorktreeException: true
                    )]
                })
            }
        }

        // MARK: - Phase 0 (Fast Cleanable): HybridCLR, CodeGraph, AI IDE Index, Old Downloads Installers
        for project in unityProjects {
            let hybridTemp = project.appendingPathComponent("HybridCLRData/StrippedAOTDllsTempProj")
            let projCodegraph = project.appendingPathComponent(".codegraph")
            if fm.fileExists(atPath: hybridTemp.path) || fm.fileExists(atPath: projCodegraph.path) {
                probes.append(ScanProbe(label: "工程构建缓存：\(project.lastPathComponent)", phase: .fastCleanable) {
                    var items: [ScanItem] = []
                    if FileManager.default.fileExists(atPath: hybridTemp.path) {
                        let size = DiskScanner.directorySize(at: hybridTemp, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                        if size >= minimumThresholdBytes {
                            items.append(ScanItem(
                                id: "tier2.hybridclr.\(project.lastPathComponent)",
                                title: "HybridCLR 临时构建工程：\(project.lastPathComponent)",
                                subtitle: "热更裁剪临时工程（下次打包可重新生成）",
                                categoryIcon: "hammer.fill",
                                tier: .caution,
                                cleanupMode: .trashItem,
                                allowedRoot: project.appendingPathComponent("HybridCLRData"),
                                targets: [hybridTemp],
                                sizeBytes: size,
                                lastModified: DiskScanner.modificationDate(at: hybridTemp)
                            ))
                        }
                    }

                    if FileManager.default.fileExists(atPath: projCodegraph.path) {
                        let size = DiskScanner.directorySize(at: projCodegraph, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                        if size >= minimumThresholdBytes {
                            items.append(ScanItem(
                                id: "tier2.codegraph.\(project.lastPathComponent)",
                                title: "CodeGraph 索引：\(project.lastPathComponent)",
                                subtitle: "项目代码图谱索引缓存，可重新索引生成",
                                categoryIcon: "point.3.connected.trianglepath.dotted",
                                tier: .caution,
                                cleanupMode: .trashItem,
                                allowedRoot: project,
                                targets: [projCodegraph],
                                sizeBytes: size
                            ))
                        }
                    }
                    return items
                })
            }
        }

        let globalCodegraph = home.appendingPathComponent(".codegraph")
        if fm.fileExists(atPath: globalCodegraph.path) {
            probes.append(ScanProbe(label: "全局 CodeGraph 缓存", phase: .fastCleanable) {
                let size = DiskScanner.directorySize(at: globalCodegraph, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= minimumThresholdBytes else { return [] }
                return [ScanItem(
                    id: "tier2.codegraph.global",
                    title: "全局 CodeGraph 缓存",
                    subtitle: "全局代码图谱缓存数据，可重建",
                    categoryIcon: "point.3.connected.trianglepath.dotted",
                    tier: .caution,
                    cleanupMode: .trashChildren,
                    allowedRoot: home,
                    targets: [globalCodegraph],
                    sizeBytes: size
                )]
            })
        }

        let lingmaIndex = home.appendingPathComponent(".lingma/index")
        if fm.fileExists(atPath: lingmaIndex.path) {
            probes.append(ScanProbe(label: "通义灵码本地索引", phase: .fastCleanable) {
                let size = DiskScanner.directorySize(at: lingmaIndex, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= minimumThresholdBytes else { return [] }
                return [ScanItem(
                    id: "tier2.lingma.index",
                    title: "通义灵码本地索引 (.lingma/index)",
                    subtitle: "补全/向量/对话检索索引，删后若继续使用会重建",
                    categoryIcon: "brain",
                    tier: .caution,
                    cleanupMode: .trashChildren,
                    allowedRoot: home.appendingPathComponent(".lingma"),
                    targets: [lingmaIndex],
                    sizeBytes: size
                )]
            })
        }

        let qoderIndex = home.appendingPathComponent(".qoder/shared_client/index")
        if fm.fileExists(atPath: qoderIndex.path) {
            let qoderWarn = runningWarning(for: ["qoder"], runningApps: runningApps, appDisplayName: "Qoder")
            probes.append(ScanProbe(label: "Qoder 本地代码索引", phase: .fastCleanable) {
                let size = DiskScanner.directorySize(at: qoderIndex, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= minimumThresholdBytes else { return [] }
                return [ScanItem(
                    id: "tier2.qoder.index",
                    title: "Qoder 本地代码索引",
                    subtitle: "Qoder 共享客户端代码索引，删后若继续使用会重建",
                    categoryIcon: "brain",
                    tier: .caution,
                    cleanupMode: .trashChildren,
                    allowedRoot: home.appendingPathComponent(".qoder/shared_client"),
                    targets: [qoderIndex],
                    sizeBytes: size,
                    runningAppWarning: qoderWarn
                )]
            })
        }

        if hasFDA {
            let downloads = home.appendingPathComponent("Downloads")
            probes.append(ScanProbe(label: "Downloads 旧安装包", phase: .fastCleanable) {
                let oldInstallers = DiskScanner.filterOldDownloads(in: downloads)
                return oldInstallers.compactMap { installer in
                    guard installer.sizeBytes >= minimumThresholdBytes else { return nil }
                    let dateStr = DateFormatter.localizedString(from: installer.modified, dateStyle: .short, timeStyle: .none)
                    return ScanItem(
                        id: "tier2.downloads.\(installer.url.lastPathComponent)",
                        title: "旧安装包：\(installer.url.lastPathComponent)",
                        subtitle: "下载于 \(dateStr)（超过 7 天的 .\(installer.url.pathExtension) 安装镜像）",
                        categoryIcon: "opticaldiscdrive",
                        tier: .caution,
                        cleanupMode: .trashItem,
                        allowedRoot: downloads,
                        targets: [installer.url],
                        sizeBytes: installer.sizeBytes,
                        lastModified: installer.modified
                    )
                }
            })
        }

        // MARK: - Phase 1 (Space Insights): Read-Only Engines & Applications
        let tuanjieEditors = appsDir.appendingPathComponent("Tuanjie/Hub/Editor")
        if let versions = try? fm.contentsOfDirectory(at: tuanjieEditors, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for ver in versions {
                probes.append(ScanProbe(label: "团结引擎 \(ver.lastPathComponent)", phase: .spaceInsights) {
                    let size = DiskScanner.directorySize(at: ver, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    guard size >= 100_000_000 else { return [] }
                    return [ScanItem(
                        id: "tier3.engine.tuanjie.\(ver.lastPathComponent)",
                        title: "团结引擎 \(ver.lastPathComponent)",
                        subtitle: "如已升级至新版，可在团结 Hub 中卸载旧版本",
                        categoryIcon: "cube.fill",
                        tier: .readOnly,
                        cleanupMode: .readOnly,
                        allowedRoot: tuanjieEditors,
                        targets: [ver],
                        sizeBytes: size,
                        guidance: "请在「Tuanjie Hub → 安装」中卸载不需要的引擎版本"
                    )]
                })
            }
        }

        let unityEditors = appsDir.appendingPathComponent("Unity/Hub/Editor")
        if let versions = try? fm.contentsOfDirectory(at: unityEditors, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for ver in versions {
                probes.append(ScanProbe(label: "Unity \(ver.lastPathComponent)", phase: .spaceInsights) {
                    let size = DiskScanner.directorySize(at: ver, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    guard size >= 100_000_000 else { return [] }
                    return [ScanItem(
                        id: "tier3.engine.unity.\(ver.lastPathComponent)",
                        title: "Unity \(ver.lastPathComponent)",
                        subtitle: "Unity Hub 托管引擎版本",
                        categoryIcon: "cube.fill",
                        tier: .readOnly,
                        cleanupMode: .readOnly,
                        allowedRoot: unityEditors,
                        targets: [ver],
                        sizeBytes: size,
                        guidance: "请在「Unity Hub → Installs」中管理卸载"
                    )]
                })
            }
        }

        let standaloneUnity = appsDir.appendingPathComponent("Unity/Unity.app")
        if fm.fileExists(atPath: standaloneUnity.path) {
            probes.append(ScanProbe(label: "Unity Standalone", phase: .spaceInsights) {
                let size = DiskScanner.directorySize(at: standaloneUnity, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                let playback = appsDir.appendingPathComponent("Unity/PlaybackEngines")
                let playbackSize = FileManager.default.fileExists(atPath: playback.path)
                    ? DiskScanner.directorySize(at: playback, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    : 0
                let ver = readBundleVersion(appURL: standaloneUnity) ?? "2022"
                return [ScanItem(
                    id: "tier3.engine.unity.standalone",
                    title: "Unity \(ver) + PlaybackEngines",
                    subtitle: "编辑器本体与 iOS/WebGL/Android 构建模块",
                    categoryIcon: "cube.fill",
                    tier: .readOnly,
                    cleanupMode: .readOnly,
                    allowedRoot: appsDir.appendingPathComponent("Unity"),
                    targets: [appsDir.appendingPathComponent("Unity")],
                    displayPathURL: standaloneUnity,
                    sizeBytes: size + playbackSize,
                    guidance: "如需删减构建平台模块，请在 Unity 安装器或 Finder 谨慎操作"
                )]
            })
        }

        if let appEntries = try? fm.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for app in appEntries {
                let name = app.lastPathComponent
                if name == "Tuanjie" || name == "Unity" { continue }
                let appDisplay = name.replacingOccurrences(of: ".app", with: "")
                probes.append(ScanProbe(label: "应用：\(appDisplay)", phase: .spaceInsights) {
                    let size = DiskScanner.directorySize(at: app, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    guard size >= 500_000_000 else { return [] }
                    return [ScanItem(
                        id: "tier3.app.\(name)",
                        title: "应用：\(appDisplay)",
                        subtitle: "已安装桌面应用程序（仅查看）",
                        categoryIcon: "app.badge",
                        tier: .readOnly,
                        cleanupMode: .readOnly,
                        allowedRoot: appsDir,
                        targets: [app],
                        sizeBytes: size,
                        guidance: "不需要该应用时，可在「访达 → 应用程序」中手动移入废纸篓"
                    )]
                })
            }
        }

        // MARK: - Phase 1 (Space Insights): IM Containers
        let containers = home.appendingPathComponent("Library/Containers")
        let containerSpecs: [(id: String, title: String, guidance: String)] = [
            ("com.tencent.xinWeChat", "微信容器数据", "请在微信「设置 → 存储空间管理」中清理缓存与聊天文件"),
            ("5ZSL2CJU2T.com.dingtalk.mac", "钉钉容器数据", "请在钉钉「设置 → 通用 → 存储空间」中清理缓存"),
            ("com.youku.mac", "优酷视频容器", "请在优酷客户端内清理离线视频与缓存"),
            ("com.bytedance.douyin.desktop", "抖音桌面端容器", "请在抖音设置中清理视频缓存")
        ]
        for spec in containerSpecs {
            let target = containers.appendingPathComponent(spec.id)
            guard fm.fileExists(atPath: target.path) else { continue }
            probes.append(ScanProbe(label: spec.title, phase: .spaceInsights) {
                let size = DiskScanner.directorySize(at: target, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= 100_000_000 else { return [] }
                return [ScanItem(
                    id: "tier3.container.\(spec.id)",
                    title: spec.title,
                    subtitle: spec.guidance,
                    categoryIcon: "message.circle",
                    tier: .readOnly,
                    cleanupMode: .readOnly,
                    allowedRoot: containers,
                    targets: [target],
                    sizeBytes: size,
                    guidance: spec.guidance
                )]
            })
        }

        // MARK: - Phase 1 (Space Insights): Home Large Folders (per-directory concurrent, single-pass cache)
        if let homeItems = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            let skipHomeNames = Set(["Library", "Downloads", ".Trash", ".npm", ".cache", ".codex", ".lingma", ".qoder"])
            let unityProjectSet = Set(unityProjects.map { $0.standardizedFileURL })
            for dir in homeItems {
                let name = dir.lastPathComponent
                if skipHomeNames.contains(name) { continue }
                let vals = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard vals?.isSymbolicLink != true, vals?.isDirectory == true else { continue }
                let isBackup = name.localizedCaseInsensitiveContains("backup")
                let isUnity = unityProjectSet.contains(dir.standardizedFileURL)

                probes.append(ScanProbe(label: "目录：\(name)", phase: .spaceInsights) {
                    let size = DiskScanner.directorySize(at: dir, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    guard size >= 1_000_000_000 || isBackup else { return [] }
                    guard size >= 50_000_000 else { return [] }

                    var notes: [String] = []
                    if isBackup { notes.append("疑似历史备份目录") }
                    let gitDir = dir.appendingPathComponent(".git")
                    if FileManager.default.fileExists(atPath: gitDir.path) {
                        let gitSize = sizeCache?.size(for: gitDir)
                            ?? DiskScanner.directorySize(at: gitDir, cache: sizeCache, cacheDepth: 2, cancelFlag: cancelFlag)
                        notes.append(".git 占 \(DiskByteFormatter.string(from: gitSize))")
                    }
                    let unityLib = dir.appendingPathComponent("Library")
                    if isUnity, FileManager.default.fileExists(atPath: unityLib.path) {
                        let libSize = sizeCache?.size(for: unityLib)
                            ?? DiskScanner.directorySize(at: unityLib, cache: sizeCache, cacheDepth: 2, cancelFlag: cancelFlag)
                        notes.append("Unity Library 占 \(DiskByteFormatter.string(from: libSize))")
                    }
                    let subtitle = notes.isEmpty ? "主目录大文件夹（仅查看，保护你的代码与资料）" : notes.joined(separator: " · ")

                    return [ScanItem(
                        id: "tier3.home.\(name)",
                        title: "目录：\(name)",
                        subtitle: subtitle,
                        categoryIcon: isBackup ? "clock.arrow.circlepath" : "folder.fill",
                        tier: .readOnly,
                        cleanupMode: .readOnly,
                        allowedRoot: home,
                        targets: [dir],
                        sizeBytes: size,
                        guidance: "请在 Finder 中查看并确认后再手动归档或删除"
                    )]
                })
            }
        }

        // MARK: - Phase 1 (Space Insights): Application Support & Trash (per-directory concurrent)
        if hasFDA {
            let appSupport = home.appendingPathComponent("Library/Application Support")
            if let children = try? fm.contentsOfDirectory(
                at: appSupport,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) {
                for dir in children {
                    let vals = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard vals?.isSymbolicLink != true, vals?.isDirectory == true else { continue }
                    let dirName = dir.lastPathComponent
                    probes.append(ScanProbe(label: "Application Support：\(dirName)", phase: .spaceInsights) {
                        let size = DiskScanner.directorySize(at: dir, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                        guard size >= 500_000_000 else { return [] }
                        return [ScanItem(
                            id: "tier3.appsupport.\(dirName)",
                            title: "Application Support：\(dirName)",
                            subtitle: "应用持久化数据与扩展支持目录",
                            categoryIcon: "internaldrive",
                            tier: .readOnly,
                            cleanupMode: .readOnly,
                            allowedRoot: appSupport,
                            targets: [dir],
                            sizeBytes: size,
                            guidance: "可在 Finder 中确认是否属于已卸载软件的残留"
                        )]
                    })
                }
            }

            let trashURL = home.appendingPathComponent(".Trash")
            if fm.fileExists(atPath: trashURL.path) {
                probes.append(ScanProbe(label: "废纸篓当前占用", phase: .spaceInsights) {
                    let trashSize = DiskScanner.directorySize(at: trashURL, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                    guard trashSize >= minimumThresholdBytes else { return [] }
                    return [ScanItem(
                        id: "tier3.trash",
                        title: "废纸篓当前占用",
                        subtitle: "已删除但尚未清倒的文件仍占用磁盘空间",
                        categoryIcon: "trash",
                        tier: .readOnly,
                        cleanupMode: .readOnly,
                        allowedRoot: home,
                        targets: [trashURL],
                        sizeBytes: trashSize,
                        guidance: "点击底部「打开废纸篓」并在 Finder 确认清倒后即可释放空间"
                    )]
                })
            }
        }

        // MARK: - Phase 1 (Space Insights): System Caches, Updates, Snapshots, Chrome Clones
        let simCaches = sysLib.appendingPathComponent("Developer/CoreSimulator/Caches")
        if fm.fileExists(atPath: simCaches.path) {
            probes.append(ScanProbe(label: "系统模拟器 dyld 缓存", phase: .spaceInsights) {
                let size = DiskScanner.directorySize(at: simCaches, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= 100_000_000 else { return [] }
                return [ScanItem(
                    id: "tier3.sys.simcaches",
                    title: "系统模拟器 dyld 缓存",
                    subtitle: "系统级目录，需管理员权限（不自动删除）",
                    categoryIcon: "lock.shield",
                    tier: .readOnly,
                    cleanupMode: .readOnly,
                    allowedRoot: sysLib,
                    targets: [simCaches],
                    sizeBytes: size,
                    guidance: "若不再使用 iOS 模拟器，可按需在终端使用 sudo 手动清理或通过 Xcode 管理"
                )]
            })
        }

        let sysUpdates = sysLib.appendingPathComponent("Updates")
        if fm.fileExists(atPath: sysUpdates.path) {
            probes.append(ScanProbe(label: "macOS 系统更新安装包缓存", phase: .spaceInsights) {
                let size = DiskScanner.directorySize(at: sysUpdates, cache: sizeCache, cacheDepth: 3, cancelFlag: cancelFlag)
                guard size >= 100_000_000 else { return [] }
                return [ScanItem(
                    id: "tier3.sys.updates",
                    title: "macOS 系统更新安装包缓存",
                    subtitle: "位于 /Library/Updates，系统更新完成并重启后自动释放",
                    categoryIcon: "arrow.down.app",
                    tier: .readOnly,
                    cleanupMode: .readOnly,
                    allowedRoot: sysLib,
                    targets: [sysUpdates],
                    sizeBytes: size,
                    guidance: "完成系统更新或重启 Mac 后系统会自动清理"
                )]
            })
        }

        probes.append(ScanProbe(label: "系统快照与签名克隆", phase: .spaceInsights) {
            var items: [ScanItem] = []

            let snapshots = DiskScanner.localUpdateSnapshots()
            if !snapshots.isEmpty {
                items.append(ScanItem(
                    id: "tier3.sys.snapshots",
                    title: "APFS 本地快照 (\(snapshots.count) 个)",
                    subtitle: snapshots.joined(separator: ", "),
                    categoryIcon: "clock.badge.checkmark",
                    tier: .readOnly,
                    cleanupMode: .readOnly,
                    allowedRoot: URL(fileURLWithPath: "/"),
                    targets: [URL(fileURLWithPath: "/")],
                    sizeBytes: 0,
                    guidance: "包含系统更新准备快照，重启或安装 macOS 更新后自动释放"
                ))
            }

            let cloneCount = DiskScanner.chromeCodeSignCloneCount()
            if cloneCount > 0 {
                let cloneRoot = URL(fileURLWithPath: NSTemporaryDirectory())
                    .deletingLastPathComponent()
                    .appendingPathComponent("X/com.google.Chrome.code_sign_clone")
                items.append(ScanItem(
                    id: "tier3.sys.chromeclones",
                    title: "Chrome 签名克隆残留 (\(cloneCount) 份)",
                    subtitle: "APFS 克隆临时副本（重启 Mac 即可自动回收，不计入重复体积）",
                    categoryIcon: "doc.on.doc",
                    tier: .readOnly,
                    cleanupMode: .readOnly,
                    allowedRoot: cloneRoot.deletingLastPathComponent(),
                    targets: [cloneRoot],
                    sizeBytes: 0,
                    guidance: "请重启 Mac 让系统自动回收旧版签名克隆副本"
                ))
            }

            return items
        })

        return probes
    }
}
