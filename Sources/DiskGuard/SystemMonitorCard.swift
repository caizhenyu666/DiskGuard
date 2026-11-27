import SwiftUI
import DiskGuardCore

enum MemoryByteFormatter {
    static func string(from bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }
}

struct SystemMonitorCard: View {
    @ObservedObject var viewModel: AppViewModel

    private var memory: MemoryStats { viewModel.systemSnapshot.memory }
    private var cpu: CPUStats { viewModel.systemSnapshot.cpu }

    private var pressureColor: Color {
        switch memory.pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            memorySection
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(height: 54)

            cpuSection
                .frame(width: 280, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - RAM Section

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(pressureColor)

                Text("运行内存")
                    .font(.system(size: 12, weight: .semibold))

                Text(memory.pressure.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(pressureColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(pressureColor.opacity(0.14))
                    .clipShape(Capsule())

                Spacer()

                Text("已用 \(MemoryByteFormatter.string(from: memory.usedBytes)) / \(MemoryByteFormatter.string(from: memory.totalBytes)) (\(Int((memory.usedRatio * 100).rounded()))%)")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
            }

            GeometryReader { geo in
                let total = max(1, Double(memory.totalBytes))
                let appFrac = Double(memory.appBytes) / total
                let wiredFrac = Double(memory.wiredBytes) / total
                let compFrac = Double(memory.compressedBytes) / total

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))

                    HStack(spacing: 1) {
                        if appFrac > 0 {
                            Rectangle()
                                .fill(Color.blue.opacity(0.85))
                                .frame(width: max(2, geo.size.width * appFrac))
                        }
                        if wiredFrac > 0 {
                            Rectangle()
                                .fill(Color.orange.opacity(0.85))
                                .frame(width: max(2, geo.size.width * wiredFrac))
                        }
                        if compFrac > 0 {
                            Rectangle()
                                .fill(Color.purple.opacity(0.85))
                                .frame(width: max(2, geo.size.width * compFrac))
                        }
                    }
                    .clipShape(Capsule())
                    .animation(.easeInOut(duration: 0.25), value: memory.usedBytes)
                }
            }
            .frame(height: 8)

            HStack(spacing: 10) {
                miniDot(color: .blue, text: "App \(MemoryByteFormatter.string(from: memory.appBytes))")
                miniDot(color: .orange, text: "联动 \(MemoryByteFormatter.string(from: memory.wiredBytes))")
                miniDot(color: .purple, text: "压缩 \(MemoryByteFormatter.string(from: memory.compressedBytes))")
                miniDot(color: .secondary.opacity(0.6), text: "缓存 \(MemoryByteFormatter.string(from: memory.cachedFilesBytes))")
                if memory.swapUsedBytes >= 100_000_000 {
                    Text("交换 \(MemoryByteFormatter.string(from: memory.swapUsedBytes))")
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if !viewModel.systemSnapshot.topProcesses.isEmpty {
                HStack(spacing: 6) {
                    Text("占用最高:")
                        .foregroundStyle(.secondary)
                    ForEach(viewModel.systemSnapshot.topProcesses.prefix(4)) { proc in
                        Text("\(proc.name) \(MemoryByteFormatter.string(from: proc.footprintBytes))")
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10).monospacedDigit())
                .lineLimit(1)
            }
        }
    }

    // MARK: - CPU & Floating HUD Section

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.teal)

                Text("CPU")
                    .font(.system(size: 12, weight: .semibold))

                Text(String(format: "%.1f%%", cpu.totalUsage * 100))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(cpu.totalUsage >= 0.8 ? .orange : .primary)

                Spacer()

                Button {
                    viewModel.toggleFloatingHUDPin()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.floatingHUDAlwaysOn ? "pip.fill" : "pip.enter")
                            .font(.system(size: 10.5))
                        Text(viewModel.floatingHUDAlwaysOn ? "悬浮窗已钉住" : "右上角悬浮窗")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(viewModel.floatingHUDAlwaysOn ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
                    .foregroundStyle(viewModel.floatingHUDAlwaysOn ? Color.accentColor : Color.primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("点击常驻/取消右上角透明悬浮监控窗；未钉住时会在窗口最小化后自动显示")
            }

            HStack(alignment: .bottom, spacing: 2) {
                let samples = paddedSamples(viewModel.cpuHistory, count: 24)
                ForEach(Array(samples.enumerated()), id: \.offset) { _, val in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(barColor(for: val))
                        .frame(height: max(2, 22 * min(1.0, max(0.0, val))))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 22, alignment: .bottom)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack(spacing: 8) {
                Text(String(format: "用户 %.0f%% · 系统 %.0f%%", cpu.userUsage * 100, cpu.systemUsage * 100))
                Spacer()
                Text(String(format: "负载 %.2f · %d核", cpu.loadAverage1m, cpu.coreCount))
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func paddedSamples(_ history: [Double], count: Int) -> [Double] {
        if history.count >= count {
            return Array(history.suffix(count))
        }
        return Array(repeating: 0, count: count - history.count) + history
    }

    private func barColor(for value: Double) -> Color {
        if value >= 0.8 { return .red.opacity(0.85) }
        if value >= 0.5 { return .orange.opacity(0.85) }
        return .teal.opacity(0.85)
    }

    private func miniDot(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
        }
    }
}
