import SwiftUI
import DiskGuardCore

struct SystemHealthView: View {
    @ObservedObject var viewModel: AppViewModel

    private var health: MacHealthStats { viewModel.systemSnapshot.health }
    private var memory: MemoryStats { viewModel.systemSnapshot.memory }
    private var cpu: CPUStats { viewModel.systemSnapshot.cpu }

    private var thermalColor: Color {
        switch health.thermal {
        case .nominal: return .green
        case .fair: return .orange
        case .serious, .critical: return .red
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    thermalAndUptimeCard
                    networkCard
                }

                HStack(alignment: .top, spacing: 14) {
                    hardwareAndBatteryCard
                    maintenanceAdvisorCard
                }
            }
            .padding(24)
        }
    }

    // MARK: - Thermal & Uptime

    private var thermalAndUptimeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(thermalColor)
                Text("散热与运行时间")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(health.thermal.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(thermalColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(thermalColor.opacity(0.14))
                    .clipShape(Capsule())
            }

            Divider()

            metricRow(label: "已连续开机", value: UptimeFormatter.string(seconds: health.uptimeSeconds))
            metricRow(label: "1 分钟平均负载", value: String(format: "%.2f (%d 核)", cpu.loadAverage1m, cpu.coreCount))
            metricRow(label: "内存压力", value: "\(memory.pressure.displayName)（\(Int((memory.usedRatio * 100).rounded()))%）")
            metricRow(
                label: "交换空间 (Swap)",
                value: memory.swapTotalBytes > 0
                    ? "\(MemoryByteFormatter.string(from: memory.swapUsedBytes)) / \(MemoryByteFormatter.string(from: memory.swapTotalBytes))"
                    : "未启用"
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Network Rate

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(.teal)
                Text("实时网络吞吐")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("↓ \(NetworkSpeedFormatter.string(bytesPerSec: health.network.downloadBytesPerSec))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.teal)
            }

            Divider()

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下载速率")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(NetworkSpeedFormatter.string(bytesPerSec: health.network.downloadBytesPerSec))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.teal)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("上传速率")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(NetworkSpeedFormatter.string(bytesPerSec: health.network.uploadBytesPerSec))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.blue)
                }

                Spacer()
            }

            HStack(alignment: .bottom, spacing: 3) {
                let samples = paddedSamples(viewModel.networkDownHistory, count: 24)
                let peak = max(10_240.0, samples.max() ?? 10_240.0)
                ForEach(Array(samples.enumerated()), id: \.offset) { _, val in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.teal.opacity(0.78))
                        .frame(height: max(2, 26 * min(1.0, val / peak)))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 26, alignment: .bottom)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack {
                Text("开机累计：收 \(DiskByteFormatter.string(from: Int64(min(health.network.totalReceivedBytes, UInt64(Int64.max))))) · 发 \(DiskByteFormatter.string(from: Int64(min(health.network.totalSentBytes, UInt64(Int64.max)))))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Battery / Hardware

    private var hardwareAndBatteryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: health.battery != nil ? "battery.100.bolt" : "desktopcomputer")
                    .foregroundStyle(.green)
                Text(health.battery != nil ? "电池与电源健康" : "硬件与系统概览")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            Divider()

            if let battery = health.battery {
                metricRow(
                    label: "当前电量",
                    value: "\(battery.currentPercent)%（\(battery.isCharging ? "正在充电" : (battery.isPluggedIn ? "已接电源" : "使用电池"))）"
                )
                if let cycle = battery.cycleCount {
                    metricRow(label: "循环次数", value: "\(cycle) 次")
                }
                if let maxHealth = battery.healthPercent {
                    metricRow(label: "电池最大容量", value: "\(maxHealth)%")
                }
            } else {
                metricRow(label: "设备类型", value: "桌面 Mac（无内置电池）")
            }

            metricRow(label: "macOS 版本", value: ProcessInfo.processInfo.operatingSystemVersionString)
            metricRow(label: "磁盘可用空间", value: "\(DiskByteFormatter.string(from: viewModel.volumeStats.importantAvailableBytes)) / \(DiskByteFormatter.string(from: viewModel.volumeStats.totalBytes))")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Maintenance Advisor

    private var maintenanceAdvisorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Mac 状态维护建议")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            Divider()

            ForEach(advisoryItems) { advice in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: advice.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(advice.color)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(advice.title)
                            .font(.system(size: 12.5, weight: .medium))
                        Text(advice.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let actionTitle = advice.actionTitle, let action = advice.action {
                        Button(actionTitle, action: action)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private struct AdviceItem: Identifiable {
        let id: String
        let icon: String
        let color: Color
        let title: String
        let detail: String
        let actionTitle: String?
        let action: (() -> Void)?
    }

    private var advisoryItems: [AdviceItem] {
        var list: [AdviceItem] = []

        if viewModel.volumeStats.importantAvailableBytes < 30_000_000_000 {
            list.append(AdviceItem(
                id: "disk-low",
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                title: "可用磁盘空间偏低",
                detail: "当前可用 \(DiskByteFormatter.string(from: viewModel.volumeStats.importantAvailableBytes))，建议保持 30 GB 以上空闲保证系统交换与编译流畅",
                actionTitle: "去清理",
                action: { viewModel.activeSection = .storage }
            ))
        }

        let safeTotal = viewModel.items.filter { $0.tier == .safe && $0.isSelectable }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        if safeTotal >= 500_000_000 {
            list.append(AdviceItem(
                id: "safe-cache",
                icon: "sparkles",
                color: .green,
                title: "发现 \(DiskByteFormatter.string(from: safeTotal)) 可安全清理缓存",
                detail: "均为可自动重建缓存，移入废纸篓可快速回收空间",
                actionTitle: "查看存储",
                action: { viewModel.activeSection = .storage }
            ))
        }

        if viewModel.trashBytes >= 500_000_000 {
            list.append(AdviceItem(
                id: "trash-large",
                icon: "trash.fill",
                color: .orange,
                title: "废纸篓仍占用 \(DiskByteFormatter.string(from: viewModel.trashBytes))",
                detail: "移入废纸篓的文件清倒后才会真正释放物理磁盘空间",
                actionTitle: "管理废纸篓",
                action: { viewModel.openTrashInApp() }
            ))
        }

        if memory.pressure != .normal || memory.swapUsedBytes >= 2_000_000_000 {
            list.append(AdviceItem(
                id: "mem-pressure",
                icon: "memorychip.fill",
                color: memory.pressure == .critical ? .red : .orange,
                title: "运行内存压力偏高 / Swap 达 \(MemoryByteFormatter.string(from: memory.swapUsedBytes))",
                detail: "可在「运行内存」分页关闭高占用后台应用释放内存",
                actionTitle: "管理内存",
                action: { viewModel.activeSection = .memory }
            ))
        }

        if health.uptimeSeconds >= 7 * 86_400 {
            list.append(AdviceItem(
                id: "uptime-long",
                icon: "arrow.triangle.2.circlepath.circle.fill",
                color: .blue,
                title: "已连续开机超过 \(Int(health.uptimeSeconds / 86_400)) 天",
                detail: "适时重启 Mac 可回收系统级 APFS 快照、Swap 文件与签名克隆残留",
                actionTitle: nil,
                action: nil
            ))
        }

        if health.thermal == .serious || health.thermal == .critical {
            list.append(AdviceItem(
                id: "thermal-high",
                icon: "flame.fill",
                color: .red,
                title: "设备温度偏高（\(health.thermal.displayName)）",
                detail: "建议检查「处理器 CPU」分页是否存在高占用卡死进程",
                actionTitle: "查看 CPU",
                action: { viewModel.activeSection = .cpu }
            ))
        }

        if list.isEmpty {
            list.append(AdviceItem(
                id: "all-good",
                icon: "checkmark.circle.fill",
                color: .green,
                title: "Mac 当前状态良好",
                detail: "磁盘余量、内存压力、散热与运行状态均处于健康区间",
                actionTitle: nil,
                action: nil
            ))
        }

        return list
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
        }
    }

    private func paddedSamples(_ history: [Double], count: Int) -> [Double] {
        if history.count >= count { return Array(history.suffix(count)) }
        return Array(repeating: 0, count: count - history.count) + history
    }
}
