# DiskGuard 工程与协作规范（AGENTS.md）

本文件用于指导后续所有会话窗口与编码 Agent 在一致的工程规范、安全边界、性能标准与发布更新流程下协作。发布与更新细则见 [docs/RELEASE_AND_UPDATE.md](docs/RELEASE_AND_UPDATE.md)。

---

## 1. 工程结构与技术栈

- **平台与工具链**：macOS 14+（Swift 6.0 / SwiftPM / SwiftUI + AppKit），Bundle ID：`com.local.diskguard`，默认 GitHub 仓库：`caizhenyu666/DiskGuard`（当前本地安装于 `/Applications/DiskGuard.app`）。
- **核心模块划分**：
  - `Sources/DiskGuardCore/`：纯业务逻辑、系统采样与安全校验（不直接依赖 UI 视图）
    - `Models.swift`、`RuleCatalog.swift`、`DiskScanner.swift`、`FastDirectorySizer.swift`、`SafetyGuard.swift`、`SystemMonitor.swift`、`UserPreferences.swift`、`AppUpdater.swift`
  - `Sources/DiskGuard/`：SwiftUI 应用层与窗口管理
    - `DiskGuardApp.swift`、`AppViewModel.swift`、`MainView.swift`、`ProcessMonitorViews.swift`、`SystemHealthView.swift`、`FloatingMonitorPanel.swift`、`MenuBarView.swift`、`DirectoryBrowserView.swift`、`ConfirmCleanSheet.swift`、`UpdateSheet.swift`
  - `Tests/DiskGuardCoreTests/`：Swift Testing 单元测试（`AppUpdaterTests.swift`、`DiskScannerTests.swift`、`SafetyGuardTests.swift`、`SystemMonitorTests.swift`）
  - `scripts/`：`build-app.sh`、`release.sh`、`setup-signing-cert.sh`
  - `VERSION`：单一版本真源（SemVer `X.Y.Z`，如 `1.4.1`）；`dist/`：本地构建与发布产物输出（已在 `.gitignore` 中忽略）。

---

## 2. 不可违背的安全与隐私红线

1. **存储清理安全边界**（`SafetyGuard.swift`、`RuleCatalog.swift`）
   - 默认仅通过 `FileManager.default.trashItem` 移入废纸篓；只有用户在废纸篓管理界面显式二次确认时，才允许对 `~/.Trash` 内条目执行永久删除（`permanentlyDeleteFromTrash`）。
   - 严格保持 `RiskTier` 三级管控：`safe`（可重建安全缓存）、`caution`（默认不勾选，移入废纸篓前高亮路径确认）、`readOnly`（仅洞察展示，永远不可删除）。
   - 必须通过 `allowedRoot` 规范化路径校验，拒绝符号链接跟随与 `..` 路径穿越；绝不触碰受保护系统/用户目录、IM 容器或任意 `.git/` 代码仓库，保留运行中 Unity 工程（`UnityLockfile`）与含未提交改动的 Codex worktree 锁保护。
2. **进程管理边界**（`SystemMonitor.swift`、`AppViewModel.swift`）
   - `SystemMonitorSampler.isProtectedProcess` 与 `ProcessController` 必须保护系统关键进程、其他 UID 进程以及 DiskGuard 自身 PID。
   - **所有强制结束（SIGKILL）** 与 **无 `.app` 包路径且进程数 > 1 的命令行进程组（如 `node`、`python3`）批量退出（SIGTERM）**，必须经过 `PendingProcessAction` 弹窗二次确认，严禁绕过直接强杀。
3. **本地零外网探针原则**
   - 内存、CPU、网络吞吐、温度、电池及 VPN / TUN / 系统代理识别全部使用纯本地 macOS API（`mach`、`sysctl`、`IOKit`、`libproc`、`SystemConfiguration`、`getifaddrs`），**严禁为了检测网络或 IP 发起任何外网请求**，严禁读取用户凭据或钥匙串敏感信息。
   - 应用内唯一的网络请求仅限 `AppUpdater` 访问 GitHub Releases API 与下载 `.zip` / `.sha256` 更新包。

---

## 3. Swift 6 并发与 UI 低功耗开发规范

- **零警告要求**：Debug 测试构建与 Release 构建均必须在 Swift 6 严格并发模式下保持 **0 个编译警告**。不要使用已废弃的 `String(cString: [CChar])`（使用 `decodeCBuffer` 截取空终止 UTF-8 字节）。
- **严禁重现 `MenuBarExtra` 死循环**：
  - `DiskGuardApp` 顶层禁止使用 `@StateObject` 订阅高频刷新的 `AppViewModel`，避免每 2 秒监控刷新触发整个 `Scene` 重算。
  - 传给 `MenuBarExtra(isInserted:)` 的 `Binding` 必须绑定场景级 `@AppStorage("diskguard.showMenuBarExtra")` 并带同值去重（`guard newValue != showMenuBarExtra else { return }`），严禁直接绑定 Combine `@Published` 属性（SwiftUI KVO 回写同值会触发无条件 `objectWillChange`，引发 `NSRunLoop.flushObservers()` 100% CPU 死循环）。
  - `MainWindowAccessor` 必须在 `Coordinator` 中缓存已附着的 `NSWindow`，避免反复异步重绑。
- **采样器与 UI 热路径性能守则**：
  - `proc_listallpids` 返回的是 **PID 个数**（不是字节数），严禁再除以 `MemoryLayout<Int32>.size`。
  - 静态进程信息必须走 `pidMetadataCache`（以 `rusage.ri_proc_start_abstime` 防 PID 复用），`NSWorkspace.shared.runningApplications` 仅在缓存未命中时懒加载。
  - 热路径禁止重复实例化 `ByteCountFormatter`，统一使用零分配的 `MemoryByteFormatter` / `DiskByteFormatter`。
  - 高频监控遥测统一合并为 `AppViewModel.telemetry: MonitorTelemetry`，后台采样线程预计算 `memoryGroups` 与 `cpuGroups`，禁止在轮询卡片圆环/进度条上挂 `.animation(...)`。
  - 列表交互需保留 `ProcessGroupListView` 的悬停锁定行序与手动暂停防跳动机制。

---

## 4. 标准开发与验证工作流

每次功能迭代或 Bug 修复按以下顺序推进：

1. **先定位、后方案、再编码**
   - 性能/卡死/异常问题先复现并抓证（如通过 `sample` 抓栈或最小基准脚本确认根因），再提出改动方案。
   - 涉及多模块改造或产品行为变更，先与用户确认方案范围再动手实现。
2. **编码与同步补齐测试**
   - 修改 `DiskGuardCore` 逻辑（扫描规则、安全校验、采样/VPN 分类、偏好持久化、更新解析等）时，必须在 `Tests/DiskGuardCoreTests/` 补充对应单元测试。
   - 新增或修改 `UserPreferences` Key 时，确保默认行为与已有测试不破坏兼容性。
3. **本地构建与全量验证（缺一不可）**
   - **Swift Testing 全量测试**（macOS CommandLineTools 无 XCTest，须带参数）：
     ```bash
     swift test --disable-sandbox --disable-xctest --enable-swift-testing
     ```
     > 注：`SafetyGuardTests` 包含真实 `~/.Trash` 移动测试；若在受限沙箱环境运行，先以沙箱缓存参数尝试，再用非沙箱权限执行并确认全部测试 100% 通过。
   - **Release 构建检查**：
     ```bash
     swift build --disable-sandbox -c release
     ```
   - **应用打包与实机采样（涉及启动/菜单栏/悬浮窗/轮询 UI 改动时必做）**：
     ```bash
     REQUIRE_FIXED_SIGNING=1 ./scripts/build-app.sh
     ```
     启动 `dist/DiskGuard.app` 跳过首次扫描后使用 `/usr/bin/sample <PID> 2` 检查稳态主线程应空闲于 `mach_msg2_trap`（无 `flushObservers` 自旋与异常 CPU 飙高）。
4. **收尾约束**
   - 除非用户明确要求「提交」「发布」或「覆盖本地应用」，否则**不要擅自执行** `git commit`、`git push`、`./scripts/release.sh` 或覆盖 `/Applications/DiskGuard.app`。
   - 汇报结果时只陈述本轮实际观察到的文件路径、符号名、实测结果与耗时数据。
