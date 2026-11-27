import SwiftUI
import AppKit
import DiskGuardCore

enum PendingBrowserAction: Identifiable {
    case deleteSelected([DirectoryEntry])
    case emptyTrash
    case moveChildToTrash(DirectoryEntry)

    var id: String {
        switch self {
        case .deleteSelected(let items):
            return "deleteSelected.\(items.count)"
        case .emptyTrash:
            return "emptyTrash"
        case .moveChildToTrash(let entry):
            return "moveChild.\(entry.id)"
        }
    }

    var title: String {
        switch self {
        case .deleteSelected(let items):
            return "确认彻底清除 \(items.count) 项？"
        case .emptyTrash:
            return "确认清空整个废纸篓？"
        case .moveChildToTrash(let entry):
            return "确认将「\(entry.name)」移入废纸篓？"
        }
    }

    var buttonTitle: String {
        switch self {
        case .deleteSelected: return "彻底清除"
        case .emptyTrash: return "清空废纸篓"
        case .moveChildToTrash: return "移至废纸篓"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deleteSelected, .emptyTrash: return true
        case .moveChildToTrash: return false
        }
    }
}

@MainActor
final class DirectoryBrowserViewModel: ObservableObject {
    let context: BrowserContext
    weak var mainViewModel: AppViewModel?

    @Published var stack: [URL]
    @Published var entries: [DirectoryEntry] = []
    @Published var selectedIDs: Set<String> = []
    @Published var isLoadingList = false
    @Published var isSizing = false
    @Published var isOperating = false
    @Published var errorMessage: String?
    @Published var needsFDA = false
    @Published var searchText = ""
    @Published var pendingAction: PendingBrowserAction?

    private var sizeTask: Task<Void, Never>?

    init(context: BrowserContext, mainViewModel: AppViewModel) {
        self.context = context
        self.mainViewModel = mainViewModel
        self.stack = [context.rootURL()]
    }

    var currentURL: URL {
        stack.last ?? context.rootURL()
    }

    var filteredEntries: [DirectoryEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var selectedEntries: [DirectoryEntry] {
        entries.filter { selectedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedEntries.compactMap(\.sizeBytes).reduce(0, +)
    }

    var totalKnownBytes: Int64 {
        entries.compactMap(\.sizeBytes).reduce(0, +)
    }

    var maxEntrySize: Int64 {
        max(1, filteredEntries.compactMap(\.sizeBytes).max() ?? 1)
    }

    func breadcrumbTitle(at index: Int) -> String {
        if index == 0 {
            return context.isTrash ? "废纸篓" : context.title
        }
        return stack[index].lastPathComponent
    }

    func loadCurrentDirectory() {
        sizeTask?.cancel()
        isLoadingList = true
        isSizing = false
        errorMessage = nil
        needsFDA = false
        selectedIDs.removeAll()

        let url = currentURL
        do {
            let listed = try DiskScanner.listImmediateEntries(at: url)
            self.entries = listed
            self.isLoadingList = false
            startAsyncDirectorySizing(for: listed)
        } catch let nsError as NSError {
            self.entries = []
            self.isLoadingList = false
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
                self.needsFDA = true
                self.errorMessage = "系统隐私权限拦截了此目录读取，需要授予「完全磁盘访问权限」"
            } else if nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EPERM) || nsError.code == Int(EACCES)) {
                self.needsFDA = true
                self.errorMessage = "系统隐私权限拦截了此目录读取，需要授予「完全磁盘访问权限」"
            } else {
                self.errorMessage = "无法读取目录：\(nsError.localizedDescription)"
            }
        }
    }

    private func startAsyncDirectorySizing(for listed: [DirectoryEntry]) {
        let dirTargets = listed.filter { $0.isDirectory && !$0.isSymbolicLink }
        guard !dirTargets.isEmpty else { return }

        isSizing = true
        sizeTask = Task {
            let maxConcurrency = 6
            await withTaskGroup(of: (String, Int64).self) { group in
                var iterator = dirTargets.makeIterator()
                for _ in 0..<min(maxConcurrency, dirTargets.count) {
                    if let next = iterator.next() {
                        group.addTask {
                            if Task.isCancelled { return (next.id, 0) }
                            let sz = DiskScanner.directorySize(at: next.url)
                            return (next.id, sz)
                        }
                    }
                }

                while let (entryID, size) = await group.next() {
                    if Task.isCancelled { return }
                    if let idx = self.entries.firstIndex(where: { $0.id == entryID }) {
                        self.entries[idx].sizeBytes = size
                    }
                    if let next = iterator.next() {
                        group.addTask {
                            if Task.isCancelled { return (next.id, 0) }
                            let sz = DiskScanner.directorySize(at: next.url)
                            return (next.id, sz)
                        }
                    }
                }
            }

            if Task.isCancelled { return }
            self.entries.sort { lhs, rhs in
                let ls = lhs.sizeBytes ?? -1
                let rs = rhs.sizeBytes ?? -1
                if ls != rs { return ls > rs }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            self.isSizing = false
        }
    }

    func openFolder(_ entry: DirectoryEntry) {
        guard entry.isDirectory, !entry.isSymbolicLink else { return }
        stack.append(entry.url)
        searchText = ""
        loadCurrentDirectory()
    }

    func navigateUp() {
        guard stack.count > 1 else { return }
        stack.removeLast()
        searchText = ""
        loadCurrentDirectory()
    }

    func navigateToBreadcrumb(index: Int) {
        guard index >= 0, index < stack.count - 1 else { return }
        stack = Array(stack.prefix(index + 1))
        searchText = ""
        loadCurrentDirectory()
    }

    func toggleSelection(id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func selectAll() {
        selectedIDs = Set(filteredEntries.map(\.id))
    }

    func deselectAll() {
        selectedIDs.removeAll()
    }

    func requestDeleteSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        pendingAction = .deleteSelected(targets)
    }

    func requestDeleteSingle(_ entry: DirectoryEntry) {
        pendingAction = .deleteSelected([entry])
    }

    func requestEmptyTrash() {
        pendingAction = .emptyTrash
    }

    func requestMoveChildToTrash(_ entry: DirectoryEntry) {
        guard context.canMoveChildrenToTrash, !entry.isSymbolicLink else { return }
        pendingAction = .moveChildToTrash(entry)
    }

    func executePendingAction(_ action: PendingBrowserAction) {
        pendingAction = nil
        isOperating = true

        Task {
            let safety = SafetyGuard()
            let report: CleanItemReport

            switch action {
            case .deleteSelected(let items):
                let urls = items.map(\.url)
                report = await Task.detached(priority: .userInitiated) {
                    safety.permanentlyDeleteFromTrash(targets: urls)
                }.value

            case .emptyTrash:
                report = await Task.detached(priority: .userInitiated) {
                    safety.emptyTrash()
                }.value

            case .moveChildToTrash(let entry):
                let scanItem = ScanItem(
                    id: "browser.child.\(entry.id)",
                    title: entry.name,
                    subtitle: "目录子项",
                    categoryIcon: entry.isDirectory ? "folder" : "doc",
                    tier: context.tier,
                    cleanupMode: .trashItem,
                    allowedRoot: context.allowedRootURL(),
                    targets: [entry.url],
                    sizeBytes: entry.sizeBytes ?? 0
                )
                report = await Task.detached(priority: .userInitiated) {
                    safety.trash(item: scanItem)
                }.value
            }

            self.isOperating = false
            self.mainViewModel?.appendLogs(report.messages)
            self.loadCurrentDirectory()
            self.mainViewModel?.refreshAfterBrowserMutation()
        }
    }

    func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openCurrentInFinder() {
        NSWorkspace.shared.open(currentURL)
    }

    func copyPath(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
        mainViewModel?.appendLogs([LogEntry(level: .info, message: "已复制路径：\(url.path)")])
    }
}

struct DirectoryBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: DirectoryBrowserViewModel
    @State private var hoveredID: String?

    init(context: BrowserContext, mainViewModel: AppViewModel) {
        _viewModel = StateObject(wrappedValue: DirectoryBrowserViewModel(context: context, mainViewModel: mainViewModel))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            breadcrumbAndToolbar
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

            Divider()

            bodyContent

            Divider()

            footerBar
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .frame(width: 820, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.loadCurrentDirectory()
        }
        .alert(
            viewModel.pendingAction?.title ?? "",
            isPresented: Binding(
                get: { viewModel.pendingAction != nil },
                set: { if !$0 { viewModel.pendingAction = nil } }
            ),
            presenting: viewModel.pendingAction
        ) { action in
            Button("取消", role: .cancel) {
                viewModel.pendingAction = nil
            }
            Button(action.buttonTitle, role: action.isDestructive ? .destructive : nil) {
                viewModel.executePendingAction(action)
            }
        } message: { action in
            Text(alertMessage(for: action))
        }
    }

    private func alertMessage(for action: PendingBrowserAction) -> String {
        switch action {
        case .deleteSelected(let items):
            let total = items.compactMap(\.sizeBytes).reduce(0, +)
            return "将从废纸篓彻底清除选中的 \(items.count) 个项目（\(DiskByteFormatter.string(from: total))）。彻底清除后不可恢复，并立即释放磁盘空间。"
        case .emptyTrash:
            return "将永久删除废纸篓内的全部项目。彻底清除后不可恢复，并立即释放磁盘空间。"
        case .moveChildToTrash(let entry):
            return "将「\(entry.name)」安全移入废纸篓，随时可在废纸篓中查看或恢复。"
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(headerTint.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: viewModel.context.isTrash ? "trash.fill" : "folder.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(headerTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(viewModel.context.isTrash ? "废纸篓管理" : viewModel.context.title)
                        .font(.system(size: 15, weight: .semibold))

                    if !viewModel.context.isTrash {
                        Text(viewModel.context.tier.badgeText)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(headerTint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(headerTint.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(
                    viewModel.context.isTrash
                    ? "当前层级共 \(viewModel.entries.count) 项（\(DiskByteFormatter.string(from: viewModel.totalKnownBytes))）· 彻底清除后立即释放磁盘空间"
                    : "\(DiskByteFormatter.compactPath(viewModel.currentURL)) · \(viewModel.entries.count) 项（\(DiskByteFormatter.string(from: viewModel.totalKnownBytes))）"
                )
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer()

            Button {
                viewModel.loadCurrentDirectory()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isLoadingList || viewModel.isOperating)

            Button {
                viewModel.openCurrentInFinder()
            } label: {
                Label("访达打开", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("关闭") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var headerTint: Color {
        if viewModel.context.isTrash { return .red }
        switch viewModel.context.tier {
        case .safe: return .green
        case .caution: return .orange
        case .readOnly: return .accentColor
        }
    }

    // MARK: - Breadcrumb & Action Bar

    private var breadcrumbAndToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    viewModel.navigateUp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.stack.count <= 1)
                .help("返回上一级")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(viewModel.stack.enumerated()), id: \.offset) { idx, _ in
                            if idx > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            let isCurrent = idx == viewModel.stack.count - 1
                            Button {
                                viewModel.navigateToBreadcrumb(index: idx)
                            } label: {
                                Text(viewModel.breadcrumbTitle(at: idx))
                                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(isCurrent)
                        }
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("筛选当前目录...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .frame(width: 140)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
            }

            if viewModel.context.isTrash {
                HStack(spacing: 8) {
                    Button("全选") {
                        viewModel.selectAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.filteredEntries.isEmpty || viewModel.isOperating)

                    Button("全不选") {
                        viewModel.deselectAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.selectedIDs.isEmpty || viewModel.isOperating)

                    Spacer()

                    Button(role: .destructive) {
                        viewModel.requestDeleteSelected()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash.slash")
                            if viewModel.selectedBytes > 0 {
                                Text("彻底清除选中 · \(DiskByteFormatter.string(from: viewModel.selectedBytes))")
                                    .monospacedDigit()
                            } else {
                                Text("彻底清除选中")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(viewModel.selectedEntries.isEmpty || viewModel.isOperating)

                    Button(role: .destructive) {
                        viewModel.requestEmptyTrash()
                    } label: {
                        Label("清空整个废纸篓", systemImage: "flame")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled((viewModel.stack.count == 1 && viewModel.entries.isEmpty) || viewModel.isOperating)
                }
            }
        }
    }

    // MARK: - Body

    private var bodyContent: some View {
        Group {
            if viewModel.needsFDA {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text(viewModel.errorMessage ?? "需要完全磁盘访问权限")
                        .font(.system(size: 13, weight: .medium))
                    HStack(spacing: 10) {
                        Button("前往系统设置授权") {
                            viewModel.mainViewModel?.openFullDiskAccessSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("重新加载") {
                            viewModel.loadCurrentDirectory()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = viewModel.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isLoadingList {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取目录...")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredEntries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: viewModel.context.isTrash ? "trash.slash" : "folder")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(
                        viewModel.searchText.isEmpty
                        ? (viewModel.context.isTrash ? "废纸篓已空" : "此文件夹为空")
                        : "没有匹配「\(viewModel.searchText)」的项目"
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredEntries) { entry in
                            entryRow(entry)
                            if entry.id != viewModel.filteredEntries.last?.id {
                                Divider().padding(.leading, viewModel.context.isTrash ? 44 : 16)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func entryRow(_ entry: DirectoryEntry) -> some View {
        let isSelected = viewModel.selectedIDs.contains(entry.id)
        let isHovered = hoveredID == entry.id
        let canDrill = entry.isDirectory && !entry.isSymbolicLink
        let ratio = Double(entry.sizeBytes ?? 0) / Double(viewModel.maxEntrySize)

        return HStack(spacing: 10) {
            if viewModel.context.isTrash {
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { _ in viewModel.toggleSelection(id: entry.id) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 20)
            }

            Image(systemName: entryIcon(entry))
                .font(.system(size: 14))
                .foregroundStyle(entryIconColor(entry))
                .frame(width: 24, height: 24)
                .background(entryIconColor(entry).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if entry.isSymbolicLink {
                        miniBadge("符号链接", color: .orange)
                    } else if entry.isHidden {
                        miniBadge("隐藏", color: .secondary)
                    }
                }

                HStack(spacing: 6) {
                    Text(entry.isDirectory ? "文件夹 · 双击或点右侧箭头打开" : (entry.isSymbolicLink ? "符号链接（为保安全不跟进）" : "文件"))
                    if let mod = entry.modifiedDate {
                        Text("·")
                        Text(DateFormatter.localizedString(from: mod, dateStyle: .short, timeStyle: .short))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isHovered {
                HStack(spacing: 4) {
                    Button {
                        viewModel.revealInFinder(entry.url)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("在 Finder 中显示")

                    if viewModel.context.isTrash {
                        Button(role: .destructive) {
                            viewModel.requestDeleteSingle(entry)
                        } label: {
                            Image(systemName: "trash.slash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("从废纸篓彻底清除")
                    } else if viewModel.context.canMoveChildrenToTrash && !entry.isSymbolicLink {
                        Button {
                            viewModel.requestMoveChildToTrash(entry)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("移至废纸篓")
                    }
                }
            }

            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(entryIconColor(entry).opacity(0.16))
                    .frame(width: max(3, 64 * ratio), height: 5)
            }
            .frame(width: 64, alignment: .trailing)

            if let size = entry.sizeBytes {
                Text(DiskByteFormatter.string(from: size))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(width: 76, alignment: .trailing)
            } else {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("计算中")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 76, alignment: .trailing)
            }

            if canDrill {
                Button {
                    viewModel.openFolder(entry)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 22)
                .help("打开下一级")
            } else {
                Spacer()
                    .frame(width: 22)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.08) : (isHovered ? Color.primary.opacity(0.03) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredID = hovering ? entry.id : (hoveredID == entry.id ? nil : hoveredID)
        }
        .onTapGesture(count: 2) {
            if canDrill {
                viewModel.openFolder(entry)
            }
        }
        .onTapGesture(count: 1) {
            if viewModel.context.isTrash {
                viewModel.toggleSelection(id: entry.id)
            } else if canDrill {
                viewModel.openFolder(entry)
            }
        }
        .contextMenu {
            if canDrill {
                Button {
                    viewModel.openFolder(entry)
                } label: {
                    Label("打开下一级", systemImage: "folder.badge.plus")
                }
            }

            Button {
                viewModel.revealInFinder(entry.url)
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }

            Button {
                viewModel.copyPath(entry.url)
            } label: {
                Label("复制完整路径", systemImage: "doc.on.doc")
            }

            if viewModel.context.isTrash {
                Divider()
                Button(role: .destructive) {
                    viewModel.requestDeleteSingle(entry)
                } label: {
                    Label("彻底清除（不可恢复）", systemImage: "trash.slash")
                }
            } else if viewModel.context.canMoveChildrenToTrash && !entry.isSymbolicLink {
                Divider()
                Button {
                    viewModel.requestMoveChildToTrash(entry)
                } label: {
                    Label("安全移至废纸篓", systemImage: "trash")
                }
            }
        }
    }

    private func entryIcon(_ entry: DirectoryEntry) -> String {
        if entry.isSymbolicLink { return "link" }
        if entry.isDirectory { return "folder.fill" }
        return "doc.fill"
    }

    private func entryIconColor(_ entry: DirectoryEntry) -> Color {
        if entry.isSymbolicLink { return .orange }
        if entry.isDirectory { return .accentColor }
        return .secondary
    }

    private func miniBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            if viewModel.isOperating {
                ProgressView()
                    .controlSize(.small)
                Text("正在执行安全操作...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else if viewModel.isSizing {
                ProgressView()
                    .controlSize(.small)
                Text("正在统计子文件夹体积...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    viewModel.context.isTrash
                    ? "双击文件夹进入下一级 · 勾选后可彻底清除以立即释放空间"
                    : (viewModel.context.canMoveChildrenToTrash
                       ? "双击文件夹浏览下一级 · 可按需将子项安全移至废纸篓"
                       : "只读浏览模式 · 仅支持层级查看与 Finder 定位，禁止任何删除操作")
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
