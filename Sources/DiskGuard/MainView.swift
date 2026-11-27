import SwiftUI
import DiskGuardCore

struct MainView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var floatingController: FloatingMonitorController
    @Environment(\.openWindow) private var openWindow
    @State private var hoveredID: String?

    var body: some View {
        VStack(spacing: 0) {
            topNavigationBar
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            switch viewModel.activeSection {
            case .storage:
                storageHeaderSection
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                Divider()

                toolbarSection
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)

                Divider()

                contentListSection

            case .memory:
                MemoryTabView(viewModel: viewModel)

            case .cpu:
                CPUTabView(viewModel: viewModel)

            case .health:
                SystemHealthView(viewModel: viewModel)
            }

            Divider()

            bottomDrawerSection
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            MainWindowAccessor { window in
                floatingController.attach(mainWindow: window, viewModel: viewModel)
            }
        )
        .onAppear {
            appSetupOnAppear()
        }
        .onChange(of: viewModel.showMenuBarExtra) { _, newValue in
            AppDelegate.shared?.keepAliveInMenuBar = newValue
        }
        .alert(
            viewModel.pendingProcessTermination?.title ?? "",
            isPresented: Binding(
                get: { viewModel.pendingProcessTermination != nil },
                set: { if !$0 { viewModel.cancelPendingProcessTermination() } }
            ),
            presenting: viewModel.pendingProcessTermination
        ) { action in
            Button("取消", role: .cancel) {
                viewModel.cancelPendingProcessTermination()
            }
            if action.isDestructive {
                Button(action.confirmButtonTitle, role: .destructive) {
                    viewModel.confirmPendingProcessTermination()
                }
            } else {
                Button(action.confirmButtonTitle) {
                    viewModel.confirmPendingProcessTermination()
                }
            }
        } message: { action in
            Text(action.message)
        }
        .sheet(isPresented: $viewModel.showingUpdateSheet) {
            UpdateSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showingPetManagerSheet) {
            PetImportSheet(viewModel: viewModel)
        }
        .sheet(item: Binding(
            get: { viewModel.pendingCleanItems.map { CleanSheetPayload(items: $0) } },
            set: { if $0 == nil { viewModel.cancelPendingClean() } }
        )) { payload in
            ConfirmCleanSheet(
                items: payload.items,
                onCancel: { viewModel.cancelPendingClean() },
                onConfirm: { viewModel.executePendingClean() }
            )
        }
        .sheet(item: $viewModel.activeBrowser) { context in
            DirectoryBrowserView(context: context, mainViewModel: viewModel)
        }
    }

    // MARK: - Top Navigation Bar

    private var topNavigationBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.9), Color.teal],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("DiskGuard")
                            .font(.system(size: 16, weight: .semibold))
                        versionPill
                    }
                    Text("macOS 存储与系统监控")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(MainSectionTab.allCases) { tab in
                    sectionTabButton(tab)
                }
            }
            .padding(3)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Spacer()

            HStack(spacing: 6) {
                updateToolbarButton

                Button {
                    viewModel.toggleFloatingHUDPin()
                } label: {
                    Image(systemName: viewModel.floatingHUDAlwaysOn ? "pip.fill" : "pip.enter")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .tint(viewModel.floatingHUDAlwaysOn ? .accentColor : nil)
                .help(viewModel.floatingHUDAlwaysOn ? "取消常驻右上角悬浮窗" : "在屏幕右上角常驻透明悬浮窗（最小化时也会自动显示）")

                Button {
                    viewModel.appearanceMode = viewModel.appearanceMode.next
                } label: {
                    Image(systemName: appearanceIcon)
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .help("外观模式：\(viewModel.appearanceMode.displayName)（点击切换）")

                Menu {
                    Toggle("菜单栏常驻图标", isOn: $viewModel.showMenuBarExtra)
                    Toggle("菜单栏显示实时数值", isOn: $viewModel.showMenuBarMetrics)
                        .disabled(!viewModel.showMenuBarExtra)
                    Divider()
                    Picker("悬浮窗形态", selection: $viewModel.floatingHUDMode) {
                        ForEach(FloatingHUDMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Button("管理桌宠形象…") {
                        viewModel.openPetManager()
                    }
                    Toggle("最小化时自动显示悬浮窗", isOn: $viewModel.floatingHUDOnMinimize)
                    Divider()
                    Toggle(
                        "登录时自动启动",
                        isOn: Binding(
                            get: { viewModel.launchAtLogin },
                            set: { viewModel.setLaunchAtLogin($0) }
                        )
                    )
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("常驻菜单栏与偏好设置")
            }
        }
    }

    private func appSetupOnAppear() {
        viewModel.applyAppAppearance()
        viewModel.startSystemMonitoring()
        floatingController.bind(viewModel: viewModel)
        floatingController.onRequestOpenMainWindow = { openWindow(id: "main") }
        AppDelegate.shared?.onReopenRequest = { [weak floatingController] in
            floatingController?.restoreMainWindow()
        }
        AppDelegate.shared?.keepAliveInMenuBar = viewModel.showMenuBarExtra
        if viewModel.items.isEmpty && !viewModel.isScanning {
            viewModel.startScan()
        }
        viewModel.checkForUpdatesOnLaunchIfNeeded()
    }

    private func sectionTabButton(_ tab: MainSectionTab) -> some View {
        let isSelected = viewModel.activeSection == tab
        let liveTag: String? = {
            switch tab {
            case .storage:
                return nil
            case .memory:
                return "\(Int((viewModel.systemSnapshot.memory.usedRatio * 100).rounded()))%"
            case .cpu:
                return String(format: "%.0f%%", viewModel.systemSnapshot.cpu.totalUsage * 100)
            case .health:
                return viewModel.systemSnapshot.health.vpn.shortBadgeText
            }
        }()

        return Button {
            viewModel.activeSection = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11.5, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                if let liveTag {
                    Text(liveTag)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.07))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color.clear)
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Storage Header & Capacity Bar

    private var storageHeaderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本地磁盘空间与安全清理")
                    .font(.system(size: 13, weight: .semibold))
                Text("· 默认仅移入废纸篓，绝不动你的文档与代码")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    Text("可用")
                        .foregroundStyle(.secondary)
                    Text(DiskByteFormatter.string(from: viewModel.volumeStats.importantAvailableBytes))
                        .fontWeight(.semibold)
                        .foregroundStyle(viewModel.volumeStats.importantAvailableBytes < 20_000_000_000 ? .orange : .primary)
                    Text("/ 共 \(DiskByteFormatter.string(from: viewModel.volumeStats.totalBytes))")
                        .foregroundStyle(.secondary)
                    if viewModel.volumeStats.purgeableBytes > 1_000_000_000 {
                        Text("（物理空闲 \(DiskByteFormatter.string(from: viewModel.volumeStats.physicalAvailableBytes))）")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12).monospacedDigit())
            }

            capacityBarCard

            if case .missing(let blocked) = viewModel.fdaStatus {
                fdaBanner(blockedPaths: blocked)
            }
        }
    }

    private var capacityBarCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 14) {
                    legendDot(color: .orange, text: "已用 \(DiskByteFormatter.string(from: viewModel.volumeStats.usedBytes))")
                    if viewModel.selectedBytes > 0 {
                        legendDot(color: .green, text: "已选可移入废纸篓 \(DiskByteFormatter.string(from: viewModel.selectedBytes))")
                    }
                }
                .font(.system(size: 12).monospacedDigit())

                Spacer()

                if viewModel.selectedBytes > 0 {
                    Text("清倒废纸篓后预计可用 \(DiskByteFormatter.string(from: viewModel.volumeStats.importantAvailableBytes)) → \(DiskByteFormatter.string(from: viewModel.projectedAvailableBytes))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.green)
                } else {
                    Text("勾选下方项目可实时预览释放效果")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geo in
                let total = max(1, Double(viewModel.volumeStats.totalBytes))
                let selectedFrac = min(Double(viewModel.selectedBytes) / total, Double(viewModel.volumeStats.usedBytes) / total)
                let remainingUsedFrac = max(0, Double(viewModel.volumeStats.usedBytes) / total - selectedFrac)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))

                    HStack(spacing: 1) {
                        if remainingUsedFrac > 0 {
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.orange.opacity(0.9), Color.orange.opacity(0.75)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(2, geo.size.width * remainingUsedFrac))
                        }

                        if selectedFrac > 0 {
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: max(4, geo.size.width * selectedFrac))
                        }
                    }
                    .clipShape(Capsule())
                    .animation(.easeInOut(duration: 0.25), value: viewModel.selectedBytes)
                }
            }
            .frame(height: 12)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
    }

    private func fdaBanner(blockedPaths: [String]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text("部分受保护目录未获授权扫描：\(blockedPaths.joined(separator: "、"))")
                    .font(.system(size: 12, weight: .medium))
                Text("如需扫描下载安装包、Application Support 与废纸篓占用，请在系统设置开启「完全磁盘访问权限」")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("前往系统设置") {
                viewModel.openFullDiskAccessSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("已授权，重扫") {
                viewModel.startScan()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Toolbar

    private var toolbarSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(FilterTab.allCases) { tab in
                    let isSelected = viewModel.activeFilter == tab
                    Button {
                        viewModel.activeFilter = tab
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.title)
                            Text("\(viewModel.count(for: tab))")
                                .font(.system(size: 11).monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08))
                                .clipShape(Capsule())
                        }
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isSelected ? Color.accentColor : Color.primary.opacity(0.05))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    TextField("搜索名称或路径...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 180)
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
            }

            HStack(spacing: 8) {
                Button("全选安全项") {
                    viewModel.selectAllSafe()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScanning || viewModel.isCleaning)

                Button("全不选") {
                    viewModel.deselectAll()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.selectedIDs.isEmpty || viewModel.isCleaning)

                Spacer()

                Button {
                    viewModel.startScan()
                } label: {
                    Label(viewModel.isScanning ? "扫描中..." : "重新扫描", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScanning || viewModel.isCleaning)

                Button {
                    viewModel.requestCleanSelected()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        if viewModel.selectedBytes > 0 {
                            Text("移至废纸篓 · \(DiskByteFormatter.string(from: viewModel.selectedBytes))")
                                .monospacedDigit()
                        } else {
                            Text("移至废纸篓")
                        }
                    }
                    .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(viewModel.selectedItems.isEmpty || viewModel.isScanning || viewModel.isCleaning)
            }
        }
    }

    private var appearanceIcon: String {
        switch viewModel.appearanceMode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    @ViewBuilder
    private var versionPill: some View {
        let hasUpdate: Bool = {
            if case .available = viewModel.updateState { return true }
            return false
        }()

        Button {
            viewModel.handleVersionBadgeTap()
        } label: {
            HStack(spacing: 4) {
                if hasUpdate {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
                Text(viewModel.currentVersion.displayTag)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(hasUpdate ? Color.green : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(hasUpdate ? Color.green.opacity(0.14) : Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("当前版本 \(viewModel.currentVersion.displayTag) (Build \(viewModel.currentBuildNumber)) · 点击检查更新")
    }

    @ViewBuilder
    private var updateToolbarButton: some View {
        switch viewModel.updateState {
        case .available(let release):
            Button {
                viewModel.showingUpdateSheet = true
            } label: {
                Label("更新至 \(release.tagName)", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .help("发现新版本 \(release.tagName)，点击查看并更新")

        case .downloading:
            Button {} label: {
                Label("正在更新...", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(true)

        case .checking:
            Button {} label: {
                Label("检查中...", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(true)

        case .idle, .upToDate, .failed:
            Button {
                viewModel.checkForUpdates(silent: false)
            } label: {
                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .help("检查 GitHub Releases 最新版本")
        }
    }

    // MARK: - Content List

    private var contentListSection: some View {
        let visibleTiers: [RiskTier] = viewModel.activeFilter.tier.map { [$0] } ?? RiskTier.allCases
        let hasAnyVisible = visibleTiers.contains { !viewModel.items(for: $0).isEmpty }

        return Group {
            if viewModel.isScanning && viewModel.items.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(viewModel.scanProgressText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasAnyVisible {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(viewModel.searchText.isEmpty ? "当前分类暂无发现可展示项目" : "没有匹配「\(viewModel.searchText)」的项目")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(visibleTiers) { tier in
                            let tierItems = viewModel.items(for: tier)
                            if !tierItems.isEmpty {
                                tierSectionView(tier: tier, tierItems: tierItems)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private func tierSectionView(tier: RiskTier, tierItems: [ScanItem]) -> some View {
        let isCollapsed = viewModel.collapsedTiers.contains(tier)
        let tierTotal = viewModel.totalBytes(for: tier)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.toggleSection(tier)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Circle()
                        .fill(tierColor(tier))
                        .frame(width: 8, height: 8)

                    Text(tier.displayName)
                        .font(.system(size: 13, weight: .semibold))

                    Text("· \(tier.sectionSubtitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text("\(tierItems.count) 项")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text(DiskByteFormatter.string(from: tierTotal))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 74, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor))

            if !isCollapsed {
                Divider()
                VStack(spacing: 0) {
                    ForEach(tierItems) { item in
                        itemRow(item)
                        if item.id != tierItems.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func itemRow(_ item: ScanItem) -> some View {
        let isSelected = viewModel.selectedIDs.contains(item.id)
        let isHovered = hoveredID == item.id
        let sizeRatio = Double(item.sizeBytes) / Double(viewModel.maxVisibleSizeBytes)

        return HStack(spacing: 10) {
            if item.isSelectable {
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { _ in viewModel.toggleSelection(id: item.id) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 20)
            } else {
                Image(systemName: item.lockReason != nil ? "lock.fill" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(item.lockReason != nil ? .orange : .secondary)
                    .frame(width: 20)
            }

            Image(systemName: item.categoryIcon)
                .font(.system(size: 13))
                .foregroundStyle(tierColor(item.tier))
                .frame(width: 26, height: 26)
                .background(tierColor(item.tier).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if let warn = item.runningAppWarning {
                        pillLabel(warn, color: .orange)
                    }
                    if let lock = item.lockReason {
                        pillLabel(lock, color: .red)
                    }
                }

                HStack(spacing: 6) {
                    Text(item.subtitle)
                        .lineLimit(1)
                    Text("·")
                    Text(DiskByteFormatter.compactPath(item.displayPathURL))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isHovered {
                HStack(spacing: 4) {
                    if viewModel.canBrowseInApp(item) {
                        Button {
                            viewModel.openFolderInApp(item)
                        } label: {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help(item.id == "tier3.trash" ? "在应用内管理废纸篓" : "在应用内打开下一级")
                    }

                    Button {
                        viewModel.revealInFinder(item)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("在 Finder 中显示")

                    if item.isSelectable {
                        Button {
                            viewModel.requestCleanSingle(item)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("单独移至废纸篓")
                    }
                }
            }

            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(tierColor(item.tier).opacity(0.14))
                    .frame(width: max(4, 70 * sizeRatio), height: 6)
            }
            .frame(width: 70, alignment: .trailing)

            Text(item.sizeBytes > 0 ? DiskByteFormatter.string(from: item.sizeBytes) : "提示")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .frame(width: 78, alignment: .trailing)

            Text(item.tier.badgeText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tierColor(item.tier))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(tierColor(item.tier).opacity(0.12))
                .clipShape(Capsule())
                .frame(width: 58, alignment: .center)

            if viewModel.canBrowseInApp(item) {
                Button {
                    viewModel.openFolderInApp(item)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 14)
                .help(item.id == "tier3.trash" ? "在应用内打开废纸篓" : "打开下一级")
            } else {
                Spacer()
                    .frame(width: 14)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.06) : (isHovered ? Color.primary.opacity(0.03) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
        }
        .onTapGesture(count: 2) {
            if viewModel.canBrowseInApp(item) {
                viewModel.openFolderInApp(item)
            }
        }
        .onTapGesture(count: 1) {
            if item.isSelectable {
                viewModel.toggleSelection(id: item.id)
            } else if viewModel.canBrowseInApp(item) {
                viewModel.openFolderInApp(item)
            }
        }
        .contextMenu {
            if viewModel.canBrowseInApp(item) {
                Button {
                    viewModel.openFolderInApp(item)
                } label: {
                    Label(item.id == "tier3.trash" ? "在应用内管理废纸篓" : "在应用内打开下一级", systemImage: "arrow.right.circle")
                }
                Divider()
            }

            Button {
                viewModel.revealInFinder(item)
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }

            Button {
                viewModel.copyPath(item)
            } label: {
                Label("复制完整路径", systemImage: "doc.on.doc")
            }

            if item.isSelectable {
                Divider()
                Button {
                    viewModel.requestCleanSingle(item)
                } label: {
                    Label("单独移至废纸篓", systemImage: "trash")
                }
            }
        }
    }

    private func pillLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func tierColor(_ tier: RiskTier) -> Color {
        switch tier {
        case .safe: return .green
        case .caution: return .orange
        case .readOnly: return .secondary
        }
    }

    // MARK: - Bottom Drawer

    private var bottomDrawerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if viewModel.activeSection == .storage {
                    if viewModel.isCleaning {
                        ProgressView(value: viewModel.cleanProgress)
                            .frame(width: 120)
                        Text("正在安全移入废纸篓...")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else if viewModel.isScanning {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.scanProgressText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(viewModel.scanProgressText) · 已选 \(viewModel.selectedItems.count) 项（\(DiskByteFormatter.string(from: viewModel.selectedBytes))）")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        viewModel.openTrashInApp()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            if viewModel.trashBytes > 0 {
                                Text("管理废纸篓 (\(DiskByteFormatter.string(from: viewModel.trashBytes)))")
                                    .monospacedDigit()
                            } else {
                                Text("管理废纸篓")
                            }
                        }
                        .font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    if let lastLog = viewModel.logs.last {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(logColor(lastLog.level))
                                .frame(width: 6, height: 6)
                            Text(Self.timeFormatter.string(from: lastLog.timestamp))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(lastLog.message)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else {
                        Text("实时监控运行中 · 每 2 秒更新（VPN：\(viewModel.systemSnapshot.health.vpn.displayStatusText)）")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.isLogDrawerExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isLogDrawerExpanded ? "chevron.down" : "chevron.up")
                        Text("\(viewModel.activeSection == .storage ? "清理日志" : "活动日志") (\(viewModel.logs.count))")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor))

            if viewModel.isLogDrawerExpanded {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if viewModel.logs.isEmpty {
                                Text("清理日志会显示在这里，右键任意项目可快速在 Finder 中定位或单独清理")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(viewModel.logs) { log in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(Self.timeFormatter.string(from: log.timestamp))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Circle()
                                            .fill(logColor(log.level))
                                            .frame(width: 6, height: 6)
                                            .padding(.top, 4)
                                        Text(log.message)
                                            .font(.system(size: 11.5))
                                            .textSelection(.enabled)
                                    }
                                    .id(log.id)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    }
                    .frame(height: 135)
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: viewModel.logs.count) { _, _ in
                        if let last = viewModel.logs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logColor(_ level: LogLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

private struct CleanSheetPayload: Identifiable {
    let id = UUID()
    let items: [ScanItem]
}
