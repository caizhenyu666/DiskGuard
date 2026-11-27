# DiskGuard

原生 macOS（Swift / SwiftUI）可视化存储空间管理与系统运行监控工具。

## 核心特性

- **三级存储安全管控（存储空间）**：
  - **安全缓存（Safe）**：可重建的应用缓存、Xcode 预览/编译缓存、Unity/团结引擎包缓存、npm/uv/Conda 归档包、日志与临时目录，支持「全选安全项」。
  - **开发残留 / 需确认（Caution）**：默认不勾选，移入废纸篓前高亮列出具体路径二次确认（如干净的 Codex worktree、HybridCLR 临时工程、CodeGraph/灵码/Qoder 索引、Downloads 中超过 7 天的 `.dmg`/`.pkg`）。
  - **大体积空间洞察（Read-Only）**：引擎版本、大应用、IM 容器、主目录大文件夹、`Application Support`、废纸篓与系统快照提示，程序内永远禁止删除。
- **默认移入废纸篓与废纸篓管理**：清理操作统一通过 `FileManager.default.trashItem` 移入废纸篓，不直接执行永久删除；支持应用内浏览 `~/.Trash` 并二次确认后彻底清除。
- **低功耗实时系统监控（运行内存 / CPU / 系统状态）**：
  - 全量采集系统进程并按 `.app` 应用组收敛统计内存与 CPU 占用（支持多进程一键退出、SIGKILL 二次确认、CLI 多进程防误杀提醒及悬停防跳动 / 暂停刷新）。
  - 系统状态看板涵盖散热状态、内存压力与 Swap、实时网络吞吐、电源与电池健康、macOS 系统维护建议，以及纯本地识别的 **VPN / TUN 隧道 / 系统代理状态看板**。
- **桌面悬浮窗与常驻菜单栏**：支持屏幕右上角透明/毛玻璃监控小窗（可收起为迷你胶囊、显示 VPN 徽标）、顶部菜单栏实时数值显示与「登录时自动启动」。
- **逐级下钻与设置持久化**：支持文件夹下钻与子目录体积统计，外观主题、分页标签、悬浮窗与菜单栏配置自动持久化。
- **应用内自动更新**：内置基于 GitHub Releases + SHA-256 校验与签名验证的一键自动更新与原子替换重启。

## 安全边界

- 硬编码黑名单保护 `/System`、`/Applications`、`~/Desktop`、`~/Documents`、`~/Pictures`、`~/Movies`、`~/Music`、`~/.ssh`、`~/Library/Keychains`、微信/钉钉容器与任意 `.git/` 代码仓库。
- 严格校验 `allowedRoot` 规范化路径，拒绝跟进符号链接及 `..` 路径穿越。
- 正在运行的 Unity 工程 `Temp/`（存在 `UnityLockfile`）与含未提交改动的 Codex worktree 自动锁定禁止清理。
- 所有系统监控与 VPN/代理检测仅使用本地 macOS API，不对外发起探针请求。

## 开发、测试与发布文档

- **工程与开发协作规范**：见 [AGENTS.md](AGENTS.md)
- **发布流水线与更新机制**：见 [docs/RELEASE_AND_UPDATE.md](docs/RELEASE_AND_UPDATE.md)

常用命令速查：

```bash
# 运行全部单元测试（macOS CommandLineTools + Swift Testing）
swift test --disable-sandbox --disable-xctest --enable-swift-testing

# 编译并签名输出 dist/DiskGuard.app
REQUIRE_FIXED_SIGNING=1 ./scripts/build-app.sh

# 一键测试、打包、推送并创建 GitHub Release
./scripts/release.sh <X.Y.Z> "<Release Notes>"
```
