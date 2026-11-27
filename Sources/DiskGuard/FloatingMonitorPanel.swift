import SwiftUI
import AppKit
import Combine
import DiskGuardCore

final class FloatingHUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct FloatingMonitorView: View {
    @ObservedObject var viewModel: AppViewModel
    let onRestoreMainWindow: () -> Void
    let onOpenPetManager: () -> Void
    @State private var isHovered = false

    private var memory: MemoryStats { viewModel.systemSnapshot.memory }
    private var cpu: CPUStats { viewModel.systemSnapshot.cpu }
    private var health: MacHealthStats { viewModel.systemSnapshot.health }
    private var vpn: VPNStatus { health.vpn }
    private var isTransparent: Bool { viewModel.floatingHUDStyle == .transparent }

    private var vpnColor: Color {
        switch vpn.kind {
        case .systemVPN, .tunTunnel: return Color(red: 0.22, green: 0.85, blue: 0.56)
        case .systemProxy: return Color(red: 0.36, green: 0.68, blue: 0.98)
        case .direct: return secondaryTextColor
        }
    }

    private var vpnHelpText: String {
        var parts = [vpn.displayStatusText]
        if let name = vpn.serviceName { parts.append(name) }
        if let iface = vpn.interfaceName { parts.append(iface) }
        if let proxy = vpn.proxy.summary { parts.append(proxy) }
        return parts.joined(separator: " · ")
    }

    private var pressureColor: Color {
        switch memory.pressure {
        case .normal: return Color(red: 0.22, green: 0.85, blue: 0.56)
        case .warning: return Color(red: 0.98, green: 0.65, blue: 0.20)
        case .critical: return Color(red: 0.96, green: 0.34, blue: 0.34)
        }
    }

    private var cpuAccentColor: Color {
        if cpu.totalUsage >= 0.8 { return Color(red: 0.96, green: 0.42, blue: 0.30) }
        if cpu.totalUsage >= 0.5 { return Color(red: 0.98, green: 0.68, blue: 0.22) }
        return Color(red: 0.22, green: 0.78, blue: 0.86)
    }

    var body: some View {
        Group {
            switch viewModel.floatingHUDMode {
            case .pet:
                DesktopPetView(viewModel: viewModel, onRestoreMainWindow: onRestoreMainWindow)
            case .pill:
                collapsedPillView
                    .onTapGesture(count: 2) {
                        onRestoreMainWindow()
                    }
            case .expanded:
                expandedHUDView
                    .onTapGesture(count: 2) {
                        onRestoreMainWindow()
                    }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("还原 DiskGuard 主窗口") {
                onRestoreMainWindow()
            }
            Picker("形态", selection: $viewModel.floatingHUDMode) {
                ForEach(FloatingHUDMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if viewModel.floatingHUDMode == .pet {
                Picker("大小", selection: $viewModel.petDisplaySize) {
                    ForEach(PetDisplaySize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                Menu("切换宠物") {
                    ForEach(viewModel.petAssetStore.availablePacks) { pack in
                        Button {
                            viewModel.selectPet(id: pack.id)
                        } label: {
                            if viewModel.activePetID == pack.id {
                                Label(pack.name, systemImage: "checkmark")
                            } else {
                                Text(pack.name)
                            }
                        }
                    }
                }
                Button("导入 / 管理自定义桌宠…") {
                    onOpenPetManager()
                }
            } else {
                Picker("背景样式", selection: $viewModel.floatingHUDStyle) {
                    ForEach(FloatingHUDStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }
            Divider()
            Toggle("最小化时自动显示", isOn: $viewModel.floatingHUDOnMinimize)
            Toggle("始终钉住悬浮窗", isOn: $viewModel.floatingHUDAlwaysOn)
            Divider()
            Button("隐藏悬浮窗") {
                viewModel.dismissFloatingHUD()
            }
        }
    }

    // MARK: - Collapsed Mini Pill

    private var collapsedPillView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(pressureColor)
                .frame(width: 7, height: 7)

            HStack(spacing: 4) {
                Text("内存")
                    .foregroundStyle(secondaryTextColor)
                Text("\(Int((memory.usedRatio * 100).rounded()))%")
                    .fontWeight(.semibold)
                    .foregroundStyle(primaryTextColor)
            }

            Rectangle()
                .fill(dividerColor)
                .frame(width: 1, height: 11)

            HStack(spacing: 4) {
                Text("CPU")
                    .foregroundStyle(secondaryTextColor)
                Text(String(format: "%.0f%%", cpu.totalUsage * 100))
                    .fontWeight(.semibold)
                    .foregroundStyle(cpuAccentColor)
            }

            if let badge = vpn.shortBadgeText {
                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1, height: 11)

                HStack(spacing: 3) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 9))
                    Text(badge)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(vpnColor)
                .help(vpnHelpText)
            }

            Button {
                viewModel.setFloatingHUDMode(.expanded)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(primaryTextColor)
                    .frame(width: 18, height: 18)
                    .background(buttonChipFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("展开悬浮监控窗")
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(hudBackground)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(borderGradient, lineWidth: 1)
        )
        .shadow(
            color: isTransparent ? Color.black.opacity(0.45) : .clear,
            radius: isTransparent ? 2 : 0,
            x: 0,
            y: isTransparent ? 1 : 0
        )
    }

    // MARK: - Expanded HUD

    private var expandedHUDView: some View {
        VStack(spacing: 9) {
            // Top bar
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.teal.opacity(0.9), Color.blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 16, height: 16)
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }

                Text("DiskGuard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                if let badge = vpn.shortBadgeText {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 8))
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(vpnColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(vpnColor.opacity(isTransparent ? 0.22 : 0.14))
                    .clipShape(Capsule())
                    .help(vpnHelpText)
                }

                if health.thermal != .nominal {
                    Circle()
                        .fill(health.thermal == .fair ? Color.orange : Color.red)
                        .frame(width: 6, height: 6)
                        .help("设备温度：\(health.thermal.displayName)")
                }

                Spacer()

                HStack(spacing: 4) {
                    hudIconButton(systemName: "pawprint.fill", help: "切换为桌宠") {
                        viewModel.setFloatingHUDMode(.pet)
                    }
                    hudIconButton(systemName: "chevron.up", help: "收起为迷你胶囊") {
                        viewModel.setFloatingHUDMode(.pill)
                    }
                    if isHovered {
                        hudIconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "还原主窗口") {
                            onRestoreMainWindow()
                        }
                        hudIconButton(systemName: "xmark", help: "隐藏悬浮窗") {
                            viewModel.dismissFloatingHUD()
                        }
                    }
                }
            }

            // Dual Circular Arc Gauges
            HStack(spacing: 12) {
                gaugeBlock(
                    title: "运行内存",
                    fraction: memory.usedRatio,
                    percentText: "\(Int((memory.usedRatio * 100).rounded()))%",
                    subtitle: "\(MemoryByteFormatter.compactGB(memory.usedBytes))/\(MemoryByteFormatter.compactGB(memory.totalBytes))",
                    badgeText: memory.pressure.displayName,
                    tint: pressureColor
                )

                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1, height: 50)

                gaugeBlock(
                    title: "CPU",
                    fraction: cpu.totalUsage,
                    percentText: String(format: "%.0f%%", cpu.totalUsage * 100),
                    subtitle: String(format: "负载 %.2f", cpu.loadAverage1m),
                    badgeText: "\(cpu.coreCount)核",
                    tint: cpuAccentColor
                )
            }

            Rectangle()
                .fill(dividerColor)
                .frame(height: 1)

            // Bottom telemetry strip (Network + Disk)
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.teal)
                    Text(NetworkSpeedFormatter.compact(bytesPerSec: health.network.downloadBytesPerSec))
                }

                HStack(spacing: 3) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.blue)
                    Text(NetworkSpeedFormatter.compact(bytesPerSec: health.network.uploadBytesPerSec))
                }

                Spacer(minLength: 4)

                HStack(spacing: 3) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 9))
                        .foregroundStyle(viewModel.volumeStats.importantAvailableBytes < 20_000_000_000 ? .orange : secondaryTextColor)
                    Text(DiskByteFormatter.string(from: viewModel.volumeStats.importantAvailableBytes))
                }
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(secondaryTextColor)
            .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 254)
        .background(hudBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderGradient, lineWidth: 1)
        )
        .shadow(
            color: isTransparent ? Color.black.opacity(0.55) : .clear,
            radius: isTransparent ? 2.5 : 0,
            x: 0,
            y: isTransparent ? 1 : 0
        )
    }

    private func gaugeBlock(
        title: String,
        fraction: Double,
        percentText: String,
        subtitle: String,
        badgeText: String,
        tint: Color
    ) -> some View {
        let clamped = min(1.0, max(0.0, fraction))
        return HStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(trackColor, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.72), tint],
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Text(percentText)
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(primaryTextColor)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(primaryTextColor)
                Text(subtitle)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
                Text(badgeText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(tint.opacity(isTransparent ? 0.20 : 0.14))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hudIconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(primaryTextColor)
                .frame(width: 18, height: 18)
                .background(buttonChipFill)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var hudBackground: some View {
        if isTransparent {
            Color.black.opacity(isHovered ? 0.28 : 0.14)
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    private var borderGradient: LinearGradient {
        if isTransparent {
            return LinearGradient(
                colors: [Color.white.opacity(isHovered ? 0.40 : 0.28), Color.white.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [Color.primary.opacity(0.20), Color.primary.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var primaryTextColor: Color {
        isTransparent ? .white.opacity(0.96) : .primary
    }

    private var secondaryTextColor: Color {
        isTransparent ? .white.opacity(0.76) : .secondary
    }

    private var trackColor: Color {
        isTransparent ? Color.white.opacity(0.16) : Color.primary.opacity(0.12)
    }

    private var dividerColor: Color {
        isTransparent ? Color.white.opacity(0.16) : Color.primary.opacity(0.10)
    }

    private var buttonChipFill: Color {
        isTransparent ? Color.white.opacity(0.18) : Color.primary.opacity(0.09)
    }
}

@MainActor
final class FloatingMonitorController: ObservableObject {
    private var panel: FloatingHUDPanel?
    private weak var hostingView: NSHostingView<FloatingMonitorView>?
    private weak var mainWindow: NSWindow?
    private weak var boundViewModel: AppViewModel?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var panelMoveObserver: NSObjectProtocol?
    private var hasPositionedOnce = false
    private var isProgrammaticFrameUpdate = false
    var onRequestOpenMainWindow: (() -> Void)?

    func bind(viewModel: AppViewModel) {
        guard boundViewModel !== viewModel else { return }
        boundViewModel = viewModel
        cancellables.removeAll()

        Publishers.CombineLatest4(
            viewModel.$floatingHUDAlwaysOn,
            viewModel.$floatingHUDOnMinimize,
            viewModel.$isMainWindowMinimized,
            viewModel.$hudDismissedForCurrentMinimize
        )
        .dropFirst()
        .sink { [weak self, weak viewModel] _ in
            Task { @MainActor [weak self, weak viewModel] in
                guard let self, let viewModel else { return }
                self.syncVisibility(viewModel: viewModel)
            }
        }
        .store(in: &cancellables)

        Publishers.CombineLatest3(
            viewModel.$floatingHUDMode,
            viewModel.$floatingHUDCollapsed,
            viewModel.$petDisplaySize
        )
        .dropFirst()
        .sink { [weak self, weak viewModel] _ in
            Task { @MainActor [weak self, weak viewModel] in
                guard let self, let viewModel else { return }
                self.updatePanelSize(viewModel: viewModel)
            }
        }
        .store(in: &cancellables)

        viewModel.$telemetry
            .map(\.snapshot.health.vpn.shortBadgeText)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self, weak viewModel] _ in
                Task { @MainActor [weak self, weak viewModel] in
                    guard let self, let viewModel else { return }
                    self.updatePanelSize(viewModel: viewModel)
                }
            }
            .store(in: &cancellables)
    }

    func attach(mainWindow: NSWindow, viewModel: AppViewModel) {
        bind(viewModel: viewModel)
        if self.mainWindow === mainWindow {
            syncVisibility(viewModel: viewModel)
            return
        }

        detachObservers()
        self.mainWindow = mainWindow

        let nc = NotificationCenter.default
        let minObs = nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: mainWindow, queue: .main) { [weak self, weak viewModel] _ in
            Task { @MainActor [weak self, weak viewModel] in
                guard let self, let viewModel else { return }
                viewModel.setMainWindowMinimized(true)
                self.syncVisibility(viewModel: viewModel)
            }
        }
        let deminObs = nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: mainWindow, queue: .main) { [weak self, weak viewModel] _ in
            Task { @MainActor [weak self, weak viewModel] in
                guard let self, let viewModel else { return }
                viewModel.setMainWindowMinimized(false)
                self.syncVisibility(viewModel: viewModel)
            }
        }
        let closeObs = nc.addObserver(forName: NSWindow.willCloseNotification, object: mainWindow, queue: .main) { [weak self, weak viewModel] _ in
            Task { @MainActor [weak self, weak viewModel] in
                guard let self else { return }
                self.detachObservers()
                self.mainWindow = nil
                viewModel?.setMainWindowMinimized(false)
                if let viewModel, !viewModel.showMenuBarExtra {
                    self.teardownPanel()
                    NSApp.terminate(nil)
                    return
                }
                if let viewModel, !viewModel.shouldShowFloatingHUD {
                    self.panel?.orderOut(nil)
                }
            }
        }
        observers = [minObs, deminObs, closeObs]

        viewModel.setMainWindowMinimized(mainWindow.isMiniaturized)
        syncVisibility(viewModel: viewModel)
    }

    func syncVisibility(viewModel: AppViewModel) {
        if viewModel.shouldShowFloatingHUD {
            let panel = ensurePanel(viewModel: viewModel)
            if !hasPositionedOnce {
                if let saved = viewModel.savedFloatingHUDOrigin {
                    position(panel, at: saved)
                } else {
                    positionTopRight(panel)
                }
                hasPositionedOnce = true
            } else {
                updatePanelSize(viewModel: viewModel)
            }
            panel.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    func updatePanelSize(viewModel: AppViewModel) {
        guard let panel, let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let newSize = hostingView.fittingSize
        guard newSize.width > 0, newSize.height > 0 else { return }

        let oldFrame = panel.frame
        if abs(oldFrame.size.width - newSize.width) < 1 && abs(oldFrame.size.height - newSize.height) < 1 {
            return
        }

        // Keep top-right corner (maxX, maxY) anchored when collapsing/expanding
        var newX = oldFrame.maxX - newSize.width
        var newY = oldFrame.maxY - newSize.height

        if let screen = panel.screen ?? mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            newX = min(max(visible.minX + 8, newX), visible.maxX - newSize.width - 8)
            newY = min(max(visible.minY + 8, newY), visible.maxY - newSize.height - 8)
        }

        isProgrammaticFrameUpdate = true
        panel.setFrame(NSRect(origin: NSPoint(x: newX, y: newY), size: newSize), display: true)
        isProgrammaticFrameUpdate = false
    }

    func restoreMainWindow() {
        if let mainWindow {
            if mainWindow.isMiniaturized {
                mainWindow.deminiaturize(nil)
            }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            onRequestOpenMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func teardownPanel() {
        if let panelMoveObserver {
            NotificationCenter.default.removeObserver(panelMoveObserver)
            self.panelMoveObserver = nil
        }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        hostingView = nil
        detachObservers()
    }

    private func ensurePanel(viewModel: AppViewModel) -> FloatingHUDPanel {
        if let panel {
            return panel
        }
        let initialRect = NSRect(x: 0, y: 0, width: 254, height: 142)
        let newPanel = FloatingHUDPanel(contentRect: initialRect)
        let newHostingView = NSHostingView(
            rootView: FloatingMonitorView(
                viewModel: viewModel,
                onRestoreMainWindow: { [weak self] in
                    self?.restoreMainWindow()
                },
                onOpenPetManager: { [weak self, weak viewModel] in
                    self?.restoreMainWindow()
                    viewModel?.openPetManager()
                }
            )
        )
        newHostingView.wantsLayer = true
        newHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        newPanel.contentView = newHostingView
        newHostingView.layoutSubtreeIfNeeded()
        newPanel.setContentSize(newHostingView.fittingSize)

        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: newPanel,
            queue: .main
        ) { [weak self, weak newPanel, weak viewModel] _ in
            Task { @MainActor [weak self, weak newPanel, weak viewModel] in
                guard let self, let newPanel, let viewModel,
                      !self.isProgrammaticFrameUpdate,
                      self.hasPositionedOnce else {
                    return
                }
                viewModel.saveFloatingHUDOrigin(newPanel.frame.origin)
            }
        }

        self.panel = newPanel
        self.hostingView = newHostingView
        return newPanel
    }

    private func position(_ panel: NSPanel, at origin: CGPoint) {
        let size = panel.frame.size
        let screens = NSScreen.screens
        let matchingScreen = screens.first { $0.visibleFrame.intersects(NSRect(origin: origin, size: size)) }
            ?? mainWindow?.screen ?? NSScreen.main ?? screens.first
        guard let screen = matchingScreen else {
            panel.setFrameOrigin(origin)
            return
        }
        let visible = screen.visibleFrame
        let x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        let y = min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        isProgrammaticFrameUpdate = true
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        isProgrammaticFrameUpdate = false
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.maxX - size.width - 16
        let y = visible.maxY - size.height - 12
        isProgrammaticFrameUpdate = true
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        isProgrammaticFrameUpdate = false
    }

    private func detachObservers() {
        let nc = NotificationCenter.default
        for obs in observers {
            nc.removeObserver(obs)
        }
        observers.removeAll()
    }
}

struct MainWindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    final class Coordinator {
        weak var attachedWindow: NSWindow?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            if let window = view.window, window !== coordinator.attachedWindow {
                coordinator.attachedWindow = window
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        if let window = nsView.window, window === coordinator.attachedWindow {
            return
        }
        DispatchQueue.main.async {
            if let window = nsView.window, window !== coordinator.attachedWindow {
                coordinator.attachedWindow = window
                onWindow(window)
            }
        }
    }
}
