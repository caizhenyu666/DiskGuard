# DiskGuard 发布与更新规范

本文档定义 DiskGuard 的版本规范、签名要求、标准发布流水线、应用内自动更新机制与热修复流程。开发规范见根目录 [AGENTS.md](../AGENTS.md)。

---

## 1. 版本号与代码签名规范

1. **版本号（SemVer）**
   - 真源位于根目录 [`VERSION`](../VERSION)（格式 `MAJOR.MINOR.PATCH`，例如 `1.4.1`），Git Tag 统一为 `v<VERSION>`（如 `v1.4.1`）。
   - `CFBundleVersion`（Build 号）由 [`scripts/build-app.sh`](../scripts/build-app.sh) 自动取 `git rev-list --count HEAD` 生成。
   - **重要**：应用内 `AppUpdater` 会优先读取 GitHub Latest Release，并以 **`SemVer` 严格递增**（`latest.version > currentVersion`）判定可更新；因此已发布过的版本号和 Tag 禁止复用或覆盖。
2. **固定签名证书（保障 Full Disk Access 持久有效）**
   - 发布正式版必须使用本地固定代码签名身份 `DiskGuard Local Signing`（脚本参数 `REQUIRE_FIXED_SIGNING=1`）。
   - 若新机器或钥匙串缺少该证书，先运行一次（不要用 ad-hoc 签名发布正式版，否则用户每次更新后 macOS 会要求重新授权「完全磁盘访问权限」）：
     ```bash
     ./scripts/setup-signing-cert.sh
     ```

---

## 2. 标准发布流程（Release Pipeline）

发布前确认：
- Git 工作区所有功能/修复改动**已先提交到 `main`**（`release.sh` 只负责自动提交 `VERSION` 变更与打 Tag）。
- 本机 GitHub CLI 已登录目标账号（当前仓库 `caizhenyu666/DiskGuard`）：`gh auth status`。

### 步骤 A：执行一键发布脚本

[`scripts/release.sh`](../scripts/release.sh) 已串联完整发布动作，直接执行：

```bash
./scripts/release.sh <X.Y.Z> "<Release Notes Markdown>"
```

脚本内部会按序执行：
1. 校验 `<X.Y.Z>` 格式与 `gh auth status`，确认 `v<X.Y.Z>` Tag 尚不存在。
2. 写入新版本号到 `VERSION`。
3. 运行全量单元测试：`swift test --disable-sandbox --disable-xctest --enable-swift-testing`。
4. 以 `REQUIRE_FIXED_SIGNING=1` 执行 `./scripts/build-app.sh`：编译 `-c release`、生成图标与 `Info.plist`、使用 `DiskGuard Local Signing` 签名并输出至 `dist/DiskGuard.app`。
5. 通过 `ditto -c -k --sequesterRsrc --keepParent` 打包 `dist/DiskGuard-v<X.Y.Z>.zip`，并生成 `dist/DiskGuard-v<X.Y.Z>.zip.sha256`。
6. 若 `VERSION` 有变更则自动提交 `chore(release): bump version to <X.Y.Z>`，创建 Annotated Tag `v<X.Y.Z>` 并 `git push origin main --follow-tags`。
7. 调用 `gh release create` 发布 GitHub Release 并上传 `.zip` 与 `.sha256` 两个资产文件。

### 步骤 B：发布后线上核验

```bash
gh release view v<X.Y.Z> --json tagName,url,assets
cat dist/DiskGuard-v<X.Y.Z>.zip.sha256
```

确认 Release URL 可访问、`DiskGuard-v<X.Y.Z>.zip` 与 `DiskGuard-v<X.Y.Z>.zip.sha256` 的 `state` 均为 `uploaded` 且 SHA-256 摘要一致。

---

## 3. 本地覆盖安装 / 更新测试

当用户要求“覆盖本地 app”或本地验收正式包时，先结束旧进程，再完整替换 `/Applications/DiskGuard.app` 并启动：

```bash
pkill -x DiskGuard || true
rm -rf /Applications/DiskGuard.app && ditto dist/DiskGuard.app /Applications/DiskGuard.app
open /Applications/DiskGuard.app
```

验证安装版本与签名身份：

```bash
defaults read /Applications/DiskGuard.app/Contents/Info CFBundleShortVersionString
defaults read /Applications/DiskGuard.app/Contents/Info CFBundleVersion
codesign -dv --requirements - /Applications/DiskGuard.app
```

---

## 4. 应用内自动更新机制（`AppUpdater` 约束）

[`Sources/DiskGuardCore/AppUpdater.swift`](../Sources/DiskGuardCore/AppUpdater.swift) 与 [`Sources/DiskGuard/AppViewModel.swift`](../Sources/DiskGuard/AppViewModel.swift) 配合实现免手动重装的应用内自更新，改动相关代码时必须保证以下机制不被破坏：

1. **更新发现**：访问 GitHub API 获取 `caizhenyu666/DiskGuard` 的 `releases/latest`（公共仓库无需 token；若切为私有仓库则需配置 token / `gh auth`）。
2. **包识别约定**：Release Assets 中必须同时包含含 `DiskGuard` 的 `.zip` 包与对应 `.sha256` 校验文件（`release.sh` 已自动满足）。
3. **安全预检**：下载解压到临时目录后，必须依次通过 `SHA-256` 校验、解包定位 `.app`、`CFBundleIdentifier == "com.local.diskguard"` 校验以及 `codesign --verify` 验证。
4. **原子替换与单实例重启**：
   - `AppUpdater.installAndRelaunch` 生成临时 shell 脚本，等待当前 PID 退出（最多 5 秒，超时升级 `SIGTERM` → `SIGKILL`），先备份原 `.app` 再原子 `mv` 替换、清理 `com.apple.quarantine`，最后执行 `open "$TARGET_APP"`（**不加 `-n`**，防止双窗口或双实例）。
   - `AppViewModel.performUpdate` 触发重启时主动关闭/隐藏窗口、取消后台任务并执行 `NSApp.terminate(nil)`（不受菜单栏常驻策略阻塞）。

---

## 5. 紧急热修复规范（Hotfix）

- **禁止**对已发布的 `main` 历史或已发布的 `v*` Release Tag 执行 `git push --force`、删 Tag 或篡改线上资产。
- 发现线上严重 Bug（如崩溃、卡死、权限异常）时：
  1. 优先用 `sample` / 日志定位根因并在本地修复验证（含实机稳态采样）。
  2. 提交修复后直接递增补丁版本号（如 `v1.4.0` → `v1.4.1`）走标准 `./scripts/release.sh` 发布。
  3. 同步覆盖本地 `/Applications/DiskGuard.app` 验证，确保用户既能通过旧版「检查更新」自动升级，也能正常启动。

---

## 6. 发布前检查清单（Checklist）

- [ ] 功能改动与对应单元测试已补充，并确认工作区无无关临时文件。
- [ ] `swift test --disable-sandbox --disable-xctest --enable-swift-testing` 全量通过且 0 编译警告。
- [ ] 若改动涉及窗口生命周期、菜单栏常驻、悬浮窗或轮询 UI，已对 `dist/DiskGuard.app` 实机启动并使用 `sample` 验证稳态 CPU 正常。
- [ ] 所有代码修改已先提交至 `main`，再运行 `./scripts/release.sh <X.Y.Z> "<Release Notes>"`。
- [ ] 已核验 GitHub Release 页面与 `.zip` / `.zip.sha256` 资产上传状态；若用户要求，已同步更新本地 `/Applications/DiskGuard.app`。
