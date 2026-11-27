import SwiftUI
import AppKit
import DiskGuardCore

struct MenuBarLabelView: View {
    @ObservedObject var viewModel: AppViewModel

    private var memoryPercent: Int {
        Int((viewModel.systemSnapshot.memory.usedRatio * 100).rounded())
    }

    private var cpuPercent: Int {
        Int((viewModel.systemSnapshot.cpu.totalUsage * 100).rounded())
    }

    private var vpnBadgeSuffix: String {
        guard let badge = viewModel.systemSnapshot.health.vpn.shortBadgeText else {
            return ""
        }
        return " · \(badge)"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "externaldrive.badge.checkmark")
            if viewModel.showMenuBarMetrics {
                Text("\(memoryPercent)% · \(cpuPercent)%\(vpnBadgeSuffix)")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            }
        }
    }
}

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var floatingController: FloatingMonitorController
    @Environment(\.openWindow) private var openWindow

    private var memory: MemoryStats { viewModel.systemSnapshot.memory }
    private var cpu: CPUStats { viewModel.systemSnapshot.cpu }
    private var health: MacHealthStats { viewModel.systemSnapshot.health }
    private var vpn: VPNStatus { health.vpn }

    private var vpnColor: Color {
        switch vpn.kind {
        case .systemVPN: return .green
        case .tunTunnel: return .teal
        case .systemProxy: return .blue
        case .direct: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            headerSection

            metricsGridSection

            vpnSummaryStrip

            topAppsSection

            Divider()

            togglesSection

            Divider()

            footerActions
        }
        .padding(14)
        .frame(width: 304)
        .onAppear {
            floatingController.bind(viewModel: viewModel)
            floatingController.onRequestOpenMainWindow = { openWindow(id: "main") }
            AppDelegate.shared?.onReopenRequest = { [weak floatingController] in
                floatingController?.restoreMainWindow()
            }
            AppDelegate.shared?.keepAliveInMenuBar = viewModel.showMenuBarExtra
            viewModel.startSystemMonitoring()
        }
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.9), Color.teal],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 24, height: 24)
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("DiskGuard")
                    .font(.system(size: 13, weight: .semibold))
                Text("v\(viewModel.currentVersion.description)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(vpn.displayStatusText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(vpnColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(vpnColor.opacity(0.14))
                .clipShape(Capsule())
        }
    }

    private var metricsGridSection: some View {
        HStack(spacing: 8) {
            miniMetricTile(
                title: "运行内存",
                value: "\(Int((memory.usedRatio * 100).rounded()))%",
                subtitle: "\(MemoryByteFormatter.compactGB(memory.usedBytes))/\(MemoryByteFormatter.compactGB(memory.totalBytes))",
                tint: memory.pressure == .critical ? .red : (memory.pressure == .warning ? .orange : .green)
            )
            miniMetricTile(
                title: "CPU",
                value: String(format: "%.0f%%", cpu.totalUsage * 100),
                subtitle: String(format: "负载 %.2f", cpu.loadAverage1m),
                tint: cpu.totalUsage >= 0.8 ? .red : (cpu.totalUsage >= 0.5 ? .orange : .teal)
            )
            miniMetricTile(
                title: "可用磁盘",
                value: DiskByteFormatter.string(from: viewModel.volumeStats.importantAvailableBytes),
                subtitle: "Swap \(MemoryByteFormatter.compactGB(memory.swapUsedBytes))",
                tint: viewModel.volumeStats.importantAvailableBytes < 20_000_000_000 ? .orange : .blue
            )
        }
    }

    private func miniMetricTile(title: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13.5, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var vpnSummaryStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: vpn.isVPNActive ? "lock.shield.fill" : (vpn.proxy.isEnabled ? "network.badge.shield.half.filled" : "network"))
                .font(.system(size: 11))
                .foregroundStyle(vpnColor)

            VStack(alignment: .leading, spacing: 1) {
                let networkDetail: String = {
                    if let name = vpn.serviceName {
                        return vpn.virtualIP.map { "\(name) · \($0)" } ?? name
                    }
                    if let iface = vpn.interfaceName, vpn.isVPNActive {
                        return vpn.virtualIP.map { "\(iface) · \($0)" } ?? iface
                    }
                    if let proxySummary = vpn.proxy.summary {
                        return proxySummary
                    }
                    return vpn.localIP ?? vpn.primaryInterface ?? "直连无代理"
                }()
                Text(networkDetail)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .lineLimit(1)

                Text("↓ \(NetworkSpeedFormatter.compact(bytesPerSec: health.network.downloadBytesPerSec)) · ↑ \(NetworkSpeedFormatter.compact(bytesPerSec: health.network.uploadBytesPerSec))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("网络设置") {
                viewModel.openNetworkSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("内存占用 Top 3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("查看全部") {
                    viewModel.activeSection = .memory
                    openAndFocusMainWindow()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.accentColor)
            }

            let topGroups = Array(viewModel.systemSnapshot.memoryGroups.prefix(3))
            if topGroups.isEmpty {
                Text("正在采样进程...")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(topGroups) { group in
                    Button {
                        viewModel.activeSection = .memory
                        openAndFocusMainWindow()
                    } label: {
                        HStack(spacing: 6) {
                            Text(group.displayName)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                            if group.processCount > 1 {
                                Text("×\(group.processCount)")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(MemoryByteFormatter.string(from: group.totalFootprintBytes))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("常驻桌面悬浮窗", isOn: $viewModel.floatingHUDAlwaysOn)

            HStack(spacing: 8) {
                Text("悬浮形态")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $viewModel.floatingHUDMode) {
                    ForEach(FloatingHUDMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 196)
            }

            Toggle("菜单栏显示实时数值", isOn: $viewModel.showMenuBarMetrics)
            Toggle(
                "登录时自动启动",
                isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }
                )
            )
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11.5))
    }

    private var footerActions: some View {
        HStack {
            Button("打开 DiskGuard") {
                openAndFocusMainWindow()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Spacer()

            Button("退出") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func openAndFocusMainWindow() {
        floatingController.onRequestOpenMainWindow = { openWindow(id: "main") }
        floatingController.restoreMainWindow()
    }
}
