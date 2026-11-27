# DiskGuard

原生 macOS（Swift / SwiftUI）可视化存储空间管理与安全清理工具。

## 核心特性

- **三级安全管控**：
  - **安全缓存（Safe）**：可重建的应用缓存、Xcode 预览/编译缓存、Unity/团结引擎包缓存、npm/uv/Conda 归档包、日志与临时目录，支持「全选安全项」。
  - **开发残留 / 需确认（Caution）**：默认不勾选，移入废纸篓前高亮列出具体路径二次确认（如干净的 Codex worktree、HybridCLR 临时工程、CodeGraph/灵码/Qoder 索引、Downloads 中超过 7 天的 `.dmg`/`.pkg`）。
  - **大体积空间洞察（Read-Only）**：引擎版本、大应用、IM 容器、主目录大文件夹、`Application Support`、废纸篓与系统快照提示，程序内永远禁止删除。
- **默认移入废纸篓**：清理操作统一通过 `FileManager.default.trashItem` 移入废纸篓，不直接执行永久删除。
- **应用内废纸篓管理**：支持在应用内浏览废纸篓、多选彻底清除或清空废纸篓（仅限 `~/.Trash` 内条目并带不可恢复二次确认）。
- **逐级下钻浏览**：任意文件夹可在应用内打开下一级，支持面包屑导航与异步子目录体积统计。
- **设置持久化**：外观主题（自动 / 浅色 / 深色）、筛选标签、分组折叠与日志抽屉状态自动保存。

## 安全边界

- 硬编码黑名单保护 `/System`、`/Applications`、`~/Desktop`、`~/Documents`、`~/Pictures`、`~/Movies`、`~/Music`、`~/.ssh`、`~/Library/Keychains`、微信/钉钉容器与任意 `.git/` 代码仓库。
- 严格校验 `allowedRoot` 规范化路径，拒绝跟进符号链接及 `..` 路径穿越。
- 正在运行的 Unity 工程 `Temp/`（存在 `UnityLockfile`）与含未提交改动的 Codex worktree 自动锁定禁止清理。

## 测试与打包

运行单元测试（macOS CommandLineTools + Swift Testing）：

```bash
swift test --disable-sandbox --disable-xctest --enable-swift-testing
```

编译并打包 `.app`（输出至 `dist/DiskGuard.app`）：

```bash
./scripts/build-app.sh
```
