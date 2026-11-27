import SwiftUI
import AppKit
import DiskGuardCore

@MainActor
private enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forBundlePath path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        if let cached = icons[path] {
            return cached
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 24, height: 24)
        icons[path] = img
        return img
    }
}

struct AppIconView: View {
    let bundlePath: String?
    let fallbackSystemName: String
    let tint: Color

    var body: some View {
        if let nsImage = AppIconCache.icon(forBundlePath: bundlePath) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .frame(width: 24, height: 24)
                Image(systemName: fallbackSystemName)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
            }
        }
    }
}

// MARK: - Memory Tab

struct MemoryTabView: View {
    @ObservedObject var viewModel: AppViewModel

    private var memory: MemoryStats { viewModel.systemSnapshot.memory }

    private var pressureColor: Color {
        switch memory.pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            memorySummaryCard
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            ProcessGroupListView(viewModel: viewModel, metric: .memory)
        }
    }

    private var memorySummaryCard: some View {
        HStack(spacing: 18) {
            // Circular Ring
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: memory.usedRatio)
                    .stroke(pressureColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 1) {
                    Text("\(Int((memory.usedRatio * 100).rounded()))%")
                        .font(.system(size: 16, weight: .bold).monospacedDigit())
                    Text("已用")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 70, height: 70)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("物理内存 \(MemoryByteFormatter.string(from: memory.totalBytes))")
                        .font(.system(size: 14, weight: .semibold))
                    Text("压力：\(memory.pressure.displayName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(pressureColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(pressureColor.opacity(0.12))
                        .clipShape(Capsule())

                    Spacer()

                    Text("已用 \(MemoryByteFormatter.string(from: memory.usedBytes)) · 可用 \(MemoryByteFormatter.string(from: memory.freeBytes))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    let total = max(1, Double(memory.totalBytes))
                    let appFrac = Double(memory.appBytes) / total
                    let wiredFrac = Double(memory.wiredBytes) / total
                    let compFrac = Double(memory.compressedBytes) / total

                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        HStack(spacing: 1) {
                            if appFrac > 0 {
                                Rectangle().fill(Color.blue.opacity(0.85))
                                    .frame(width: max(2, geo.size.width * appFrac))
                            }
                            if wiredFrac > 0 {
                                Rectangle().fill(Color.orange.opacity(0.85))
                                    .frame(width: max(2, geo.size.width * wiredFrac))
                            }
                            if compFrac > 0 {
                                Rectangle().fill(Color.purple.opacity(0.85))
                                    .frame(width: max(2, geo.size.width * compFrac))
                            }
                        }
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 10)

                HStack(spacing: 14) {
                    legendItem(color: .blue, label: "App 内存 \(MemoryByteFormatter.string(from: memory.appBytes))")
                    legendItem(color: .orange, label: "联动 \(MemoryByteFormatter.string(from: memory.wiredBytes))")
                    legendItem(color: .purple, label: "被压缩 \(MemoryByteFormatter.string(from: memory.compressedBytes))")
                    legendItem(color: .secondary.opacity(0.5), label: "缓存文件 \(MemoryByteFormatter.string(from: memory.cachedFilesBytes))")
                    Spacer()
                    Text(memory.swapUsedBytes > 0
                         ? "交换空间 \(MemoryByteFormatter.string(from: memory.swapUsedBytes))"
                         : "未使用 Swap")
                        .foregroundStyle(memory.swapUsedBytes >= 1_000_000_000 ? .orange : .secondary)
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }
}

// MARK: - CPU Tab

struct CPUTabView: View {
    @ObservedObject var viewModel: AppViewModel

    private var cpu: CPUStats { viewModel.systemSnapshot.cpu }
    private var thermal: ThermalLevel { viewModel.systemSnapshot.health.thermal }

    private var cpuAccent: Color {
        if cpu.totalUsage >= 0.8 { return .red }
        if cpu.totalUsage >= 0.5 { return .orange }
        return .teal
    }

    private var thermalColor: Color {
        switch thermal {
        case .nominal: return .green
        case .fair: return .orange
        case .serious, .critical: return .red
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            cpuSummaryCard
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            ProcessGroupListView(viewModel: viewModel, metric: .cpu)
        }
    }

    private var cpuSummaryCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: cpu.totalUsage)
                    .stroke(cpuAccent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 1) {
                    Text(String(format: "%.0f%%", cpu.totalUsage * 100))
                        .font(.system(size: 16, weight: .bold).monospacedDigit())
                    Text("总占用")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 70, height: 70)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(cpu.coreCount) 核处理器")
                        .font(.system(size: 14, weight: .semibold))

                    Text("温度：\(thermal.displayName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(thermalColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(thermalColor.opacity(0.12))
                        .clipShape(Capsule())

                    Spacer()

                    Text(String(format: "用户 %.1f%% · 系统 %.1f%% · 1分钟负载 %.2f", cpu.userUsage * 100, cpu.systemUsage * 100, cpu.loadAverage1m))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .bottom, spacing: 3) {
                    let samples = paddedHistory(viewModel.cpuHistory, count: 24)
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, val in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(barColor(val))
                            .frame(height: max(3, 30 * min(1.0, max(0.0, val))))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 30, alignment: .bottom)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func paddedHistory(_ history: [Double], count: Int) -> [Double] {
        if history.count >= count { return Array(history.suffix(count)) }
        return Array(repeating: 0, count: count - history.count) + history
    }

    private func barColor(_ val: Double) -> Color {
        if val >= 0.8 { return .red.opacity(0.85) }
        if val >= 0.5 { return .orange.opacity(0.85) }
        return .teal.opacity(0.85)
    }
}

// MARK: - Converged App Group List

struct ProcessGroupListView: View {
    @ObservedObject var viewModel: AppViewModel
    let metric: ProcessSortMetric

    @State private var expandedGroupIDs: Set<String> = []
    @State private var isManuallyPaused = false
    @State private var pausedGroups: [ProcessGroup] = []
    @State private var isHoveringList = false
    @State private var frozenOrderIDs: [String] = []

    private var groups: [ProcessGroup] {
        switch metric {
        case .memory: return viewModel.memoryProcessGroups
        case .cpu: return viewModel.cpuProcessGroups
        }
    }

    private var displayedGroups: [ProcessGroup] {
        if isManuallyPaused {
            return pausedGroups
        }
        let liveGroups = groups
        guard isHoveringList, !frozenOrderIDs.isEmpty else {
            return liveGroups
        }
        var byID: [String: ProcessGroup] = [:]
        byID.reserveCapacity(liveGroups.count)
        for group in liveGroups {
            byID[group.id] = group
        }
        var ordered: [ProcessGroup] = []
        ordered.reserveCapacity(liveGroups.count)
        var seen: Set<String> = []
        seen.reserveCapacity(frozenOrderIDs.count)
        for id in frozenOrderIDs {
            if let updated = byID[id] {
                ordered.append(updated)
                seen.insert(id)
            }
        }
        for group in liveGroups where !seen.contains(group.id) {
            ordered.append(group)
        }
        return ordered
    }

    private var totalProcessCount: Int {
        displayedGroups.reduce(0) { $0 + $1.processCount }
    }

    private var maxGroupValue: Double {
        switch metric {
        case .memory:
            return max(1, Double(displayedGroups.map(\.totalFootprintBytes).max() ?? 1))
        case .cpu:
            return max(1, displayedGroups.map(\.totalCPUPercent).max() ?? 1)
        }
    }

    var body: some View {
        let rows = displayedGroups
        let maxValue = maxGroupValue

        VStack(spacing: 0) {
            filterToolbar(rows: rows)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)

            Divider()

            if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(viewModel.processSearchText.isEmpty ? "正在采集进程信息..." : "没有匹配的进程「\(viewModel.processSearchText)」")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { group in
                            let isExpanded = expandedGroupIDs.contains(group.id)
                            ProcessGroupRowView(
                                group: group,
                                metric: metric,
                                maxGroupValue: maxValue,
                                isExpanded: isExpanded,
                                onToggleExpand: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if expandedGroupIDs.contains(group.id) {
                                            expandedGroupIDs.remove(group.id)
                                        } else {
                                            expandedGroupIDs.insert(group.id)
                                        }
                                    }
                                },
                                onTerminate: { mode in
                                    viewModel.terminateGroup(group, mode: mode)
                                }
                            )

                            if isExpanded && group.processCount > 1 {
                                ForEach(group.processes) { proc in
                                    childProcessRow(proc, parentGroup: group)
                                }
                            }

                            if group.id != rows.last?.id {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onHover { hovering in
                    isHoveringList = hovering
                    if hovering {
                        frozenOrderIDs = displayedGroups.map(\.id)
                    } else {
                        frozenOrderIDs = []
                    }
                }
            }
        }
        .onChange(of: viewModel.processSearchText) { _, _ in
            frozenOrderIDs = []
            if isManuallyPaused {
                pausedGroups = groups
            }
        }
        .onChange(of: viewModel.onlyClosableProcesses) { _, _ in
            frozenOrderIDs = []
            if isManuallyPaused {
                pausedGroups = groups
            }
        }
    }

    private func filterToolbar(rows: [ProcessGroup]) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索应用或进程 / PID...", text: $viewModel.processSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 210)
                if !viewModel.processSearchText.isEmpty {
                    Button {
                        viewModel.processSearchText = ""
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

            Toggle("仅显示可关闭应用", isOn: $viewModel.onlyClosableProcesses)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            Spacer()

            if isManuallyPaused {
                Text("已暂停")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14))
                    .clipShape(Capsule())
            } else if isHoveringList {
                Text("排序已锁定")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07))
                    .clipShape(Capsule())
            }

            Text("共 \(rows.count) 个应用组 · \(totalProcessCount) 个进程（按\(metric == .memory ? "内存" : "CPU")降序）")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                if isManuallyPaused {
                    isManuallyPaused = false
                    pausedGroups = []
                } else {
                    pausedGroups = rows
                    isManuallyPaused = true
                }
            } label: {
                Label(isManuallyPaused ? "继续" : "暂停", systemImage: isManuallyPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .tint(isManuallyPaused ? .orange : nil)
            .controlSize(.small)
            .help(isManuallyPaused ? "恢复实时刷新" : "暂停刷新，防止列表位置跳动")

            Button {
                Task {
                    await viewModel.sampleSystemNow(includeProcesses: true)
                    if isManuallyPaused {
                        pausedGroups = groups
                    }
                }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func childProcessRow(_ proc: ProcessEntry, parentGroup: ProcessGroup) -> some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 34)

            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 5, height: 5)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(proc.name)
                        .font(.system(size: 12))
                        .lineLimit(1)

                    Text("PID \(proc.pid)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if parentGroup.appBundlePath == nil && !proc.executablePath.isEmpty {
                    Text(DiskByteFormatter.compactPath(URL(fileURLWithPath: proc.executablePath)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if !proc.isProtected && !parentGroup.isProtected {
                Button("结束") {
                    viewModel.terminateProcess(proc, mode: .graceful)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button(role: .destructive) {
                    viewModel.terminateProcess(proc, mode: .force)
                } label: {
                    Image(systemName: "xmark.octagon")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.mini)
                .help("强制结束此子进程")
            }

            HStack(spacing: 10) {
                Text(MemoryByteFormatter.string(from: proc.footprintBytes))
                Text(String(format: "%.1f%%", proc.cpuPercent))
                    .frame(width: 48, alignment: .trailing)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 140, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.02))
    }
}

private struct ProcessGroupRowView: View {
    let group: ProcessGroup
    let metric: ProcessSortMetric
    let maxGroupValue: Double
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onTerminate: (ProcessController.TerminateMode) -> Void

    @State private var isHovered = false

    private var ratio: Double {
        switch metric {
        case .memory: return Double(group.totalFootprintBytes) / maxGroupValue
        case .cpu: return group.totalCPUPercent / maxGroupValue
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if group.processCount > 1 {
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 16)
            }

            AppIconView(
                bundlePath: group.appBundlePath,
                fallbackSystemName: group.isProtected ? "gearshape.fill" : "terminal.fill",
                tint: group.isProtected ? .secondary : .accentColor
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if group.processCount > 1 {
                        Text("\(group.processCount) 个进程")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    } else if let onlyPID = group.processes.first?.pid {
                        Text("PID \(onlyPID)")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if group.isProtected {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                            Text("系统保护")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                    }
                }

                if let bundle = group.appBundlePath {
                    Text(bundle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            if !group.isProtected {
                HStack(spacing: 5) {
                    Button {
                        onTerminate(.graceful)
                    } label: {
                        Text(group.processCount > 1 ? "全部退出" : "退出")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(group.processCount > 1 ? "向该应用的全部 \(group.processCount) 个进程发送退出请求" : "优雅退出该进程")

                    Button(role: .destructive) {
                        onTerminate(.force)
                    } label: {
                        Image(systemName: "xmark.octagon")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                    .help("强制结束（SIGKILL）")
                }
            }

            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 3)
                    .fill((metric == .memory ? Color.blue : Color.teal).opacity(0.18))
                    .frame(width: max(4, 72 * min(1.0, max(0.0, ratio))), height: 6)
            }
            .frame(width: 72, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                if metric == .memory {
                    Text(MemoryByteFormatter.string(from: group.totalFootprintBytes))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    Text(String(format: "CPU %.1f%%", group.totalCPUPercent))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: "%.1f%%", group.totalCPUPercent))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(group.totalCPUPercent >= 80 ? .orange : .primary)
                    Text("内存 \(MemoryByteFormatter.string(from: group.totalFootprintBytes))")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            if group.processCount > 1 {
                onToggleExpand()
            }
        }
    }
}
