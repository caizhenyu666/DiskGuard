import SwiftUI
import AppKit
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
    @State private var isHovered = false

    private var memory: MemoryStats { viewModel.systemSnapshot.memory }
    private var cpu: CPUStats { viewModel.systemSnapshot.cpu }
    private var isTransparent: Bool { viewModel.floatingHUDStyle == .transparent }

    private var pressureColor: Color {
        switch memory.pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.teal)
                Text("DiskGuard")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                Spacer()

                if isHovered {
                    Button {
                        onRestoreMainWindow()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(isTransparent ? 0.22 : 0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("还原 DiskGuard 主窗口")

                    Button {
                        viewModel.dismissFloatingHUD()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(isTransparent ? 0.22 : 0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("隐藏悬浮窗")
                } else {
                    Text(String(format: "负载 %.2f", cpu.loadAverage1m))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(secondaryTextColor)
                }
            }

            // Memory Row
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .font(.system(size: 10.5))
                    .foregroundStyle(pressureColor)
                    .frame(width: 13)

                Text("内存")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(primaryTextColor)

                miniProgressBar(fraction: memory.usedRatio, tint: pressureColor)

                Text("\(Int((memory.usedRatio * 100).rounded()))% · \(MemoryByteFormatter.string(from: memory.usedBytes))")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)
            }

            // CPU Row
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.teal)
                    .frame(width: 13)

                Text("CPU")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(primaryTextColor)

                miniProgressBar(fraction: cpu.totalUsage, tint: cpu.totalUsage >= 0.8 ? .orange : .teal)

                Text(String(format: "%.1f%%", cpu.totalUsage * 100))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(primaryTextColor)
                    .frame(minWidth: 42, alignment: .trailing)
            }

            // Disk & Swap Row
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 10.5))
                    .foregroundStyle(viewModel.volumeStats.importantAvailableBytes < 20_000_000_000 ? .orange : .secondary)
                    .frame(width: 13)

                Text("磁盘可用 \(DiskByteFormatter.string(from: viewModel.volumeStats.importantAvailableBytes))")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(secondaryTextColor)

                Spacer(minLength: 4)

                if memory.swapUsedBytes >= 1_000_000_000 {
                    Text("Swap \(MemoryByteFormatter.string(from: memory.swapUsedBytes))")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: 236)
        .background(hudBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTransparent ? Color.white.opacity(isHovered ? 0.35 : 0.18) : Color.primary.opacity(0.14),
                    lineWidth: 1
                )
        )
        .shadow(
            color: isTransparent ? Color.black.opacity(0.55) : .clear,
            radius: isTransparent ? 2 : 0,
            x: 0,
            y: isTransparent ? 1 : 0
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) {
            onRestoreMainWindow()
        }
        .contextMenu {
            Button("还原 DiskGuard 主窗口") {
                onRestoreMainWindow()
            }
            Divider()
            Picker("背景样式", selection: $viewModel.floatingHUDStyle) {
                ForEach(FloatingHUDStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Toggle("最小化时自动显示", isOn: $viewModel.floatingHUDOnMinimize)
            Toggle("始终钉住悬浮窗", isOn: $viewModel.floatingHUDAlwaysOn)
            Divider()
            Button("隐藏悬浮窗") {
                viewModel.dismissFloatingHUD()
            }
        }
    }

    @ViewBuilder
    private var hudBackground: some View {
        if isTransparent {
            Color.black.opacity(isHovered ? 0.22 : 0.08)
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    private var primaryTextColor: Color {
        isTransparent ? .white.opacity(0.96) : .primary
    }

    private var secondaryTextColor: Color {
        isTransparent ? .white.opacity(0.78) : .secondary
    }

    private func miniProgressBar(fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            let clamped = min(1.0, max(0.0, fraction))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isTransparent ? Color.white.opacity(0.18) : Color.primary.opacity(0.12))
                Capsule()
                    .fill(tint.opacity(0.92))
                    .frame(width: max(3, geo.size.width * clamped))
                    .animation(.easeInOut(duration: 0.25), value: clamped)
            }
        }
        .frame(height: 5)
    }
}

@MainActor
final class FloatingMonitorController: ObservableObject {
    private var panel: FloatingHUDPanel?
    private weak var mainWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var hasPositionedOnce = false

    func attach(mainWindow: NSWindow, viewModel: AppViewModel) {
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
        let closeObs = nc.addObserver(forName: NSWindow.willCloseNotification, object: mainWindow, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.teardownPanel()
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
                positionTopRight(panel)
                hasPositionedOnce = true
            }
            panel.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    func restoreMainWindow() {
        guard let mainWindow else { return }
        if mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
        }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func teardownPanel() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        detachObservers()
    }

    private func ensurePanel(viewModel: AppViewModel) -> FloatingHUDPanel {
        if let panel {
            return panel
        }
        let initialRect = NSRect(x: 0, y: 0, width: 236, height: 96)
        let newPanel = FloatingHUDPanel(contentRect: initialRect)
        let hostingView = NSHostingView(
            rootView: FloatingMonitorView(viewModel: viewModel) { [weak self] in
                self?.restoreMainWindow()
            }
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        newPanel.contentView = hostingView
        newPanel.setContentSize(hostingView.fittingSize)
        self.panel = newPanel
        return newPanel
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.maxX - size.width - 14
        let y = visible.maxY - size.height - 12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindow(window)
            }
        }
    }
}
