import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiskGuardCore

struct PetImportSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var petName: String = ""
    @State private var moodSourceURLs: [PetMood: URL] = [:]
    @State private var removeBackground: Bool = true
    @State private var previewImage: NSImage?
    @State private var isGeneratingPreview: Bool = false
    @State private var showExtraMoods: Bool = false
    @State private var isImporting: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("桌面宠物形象")
                        .font(.system(size: 16, weight: .semibold))
                    Text("默认使用西高地白梗；也可导入 1 张或多张自定义卡通形象。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            installedPacksSection

            Divider()

            importFormSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("保存并启用") {
                    submitImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(moodSourceURLs[.idle] == nil || isImporting)
            }
        }
        .padding(18)
        .frame(width: 490)
    }

    private var installedPacksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已安装形象")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.petAssetStore.availablePacks) { pack in
                        installedPackCard(pack)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func installedPackCard(_ pack: PetPack) -> some View {
        let isActive = viewModel.activePetID == pack.id
        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 72, height: 72)
                    .overlay {
                        if let thumb = viewModel.petAssetStore.image(for: pack, mood: .idle) {
                            Image(nsImage: thumb)
                                .resizable()
                                .scaledToFit()
                                .padding(6)
                        } else {
                            Image(systemName: "pawprint.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isActive ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: isActive ? 2 : 1)
                    )

                if !pack.isBuiltIn {
                    Button {
                        deletePack(pack)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary, Color(nsColor: .windowBackgroundColor))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                    .help("删除「\(pack.name)」")
                }
            }

            HStack(spacing: 3) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
                Text(pack.name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
        }
        .frame(width: 76)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectPet(id: pack.id)
        }
    }

    private var importFormSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导入自定义宠物")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 14) {
                previewDropZone

                VStack(alignment: .leading, spacing: 9) {
                    TextField("角色名称（如：宝贝、小西）", text: $petName)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button("选择主图...") {
                            pickImage(for: .idle)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if moodSourceURLs[.idle] != nil {
                            Button("清除") {
                                moodSourceURLs.removeValue(forKey: .idle)
                                previewImage = nil
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("自动抠除背景（纯本地 Vision）", isOn: $removeBackground)
                        .font(.system(size: 11.5))
                        .onChange(of: removeBackground) { _, _ in
                            refreshPrimaryPreview()
                        }

                    Text("只需 1 张主图即可生效；其余状态自动复用主图并叠加呼吸与贴纸动效。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DisclosureGroup("可选：补充其他状态表情图", isExpanded: $showExtraMoods) {
                VStack(spacing: 6) {
                    ForEach(PetMood.allCases.filter { $0 != .idle }) { mood in
                        HStack {
                            Image(systemName: mood.badgeSymbol)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(mood.displayName)
                                .font(.system(size: 11.5))
                                .frame(width: 44, alignment: .leading)
                            Text(moodSourceURLs[mood]?.lastPathComponent ?? "默认复用主图")
                                .font(.system(size: 11))
                                .foregroundStyle(moodSourceURLs[mood] == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if moodSourceURLs[mood] != nil {
                                Button("清除") {
                                    moodSourceURLs.removeValue(forKey: mood)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            }
                            Button("选择...") {
                                pickImage(for: mood)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11.5, weight: .medium))
        }
    }

    private var previewDropZone: some View {
        ZStack {
            CheckerboardPattern()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if isGeneratingPreview {
                ProgressView()
                    .controlSize(.small)
            } else if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("拖拽图片到此处")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 112, height: 112)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                Task { @MainActor in
                    self.moodSourceURLs[.idle] = url
                    self.errorMessage = nil
                    self.refreshPrimaryPreview()
                }
            }
            return true
        }
    }

    private func pickImage(for mood: PetMood) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "选择图片"
        if panel.runModal() == .OK, let url = panel.url {
            moodSourceURLs[mood] = url
            errorMessage = nil
            if mood == .idle {
                refreshPrimaryPreview()
            }
        }
    }

    private func refreshPrimaryPreview() {
        guard let url = moodSourceURLs[.idle] else {
            previewImage = nil
            return
        }
        let stripBG = removeBackground
        isGeneratingPreview = true
        Task {
            let cg = await Task.detached(priority: .userInitiated) {
                PetAssetStore.processImage(at: url, removeBackground: stripBG, maxDimension: 320)
            }.value
            self.isGeneratingPreview = false
            if let cg {
                self.previewImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } else {
                self.previewImage = nil
                self.errorMessage = "无法解析该图片，请确认格式为 PNG / JPEG / HEIC。"
            }
        }
    }

    private func submitImport() {
        guard moodSourceURLs[.idle] != nil else { return }
        isImporting = true
        errorMessage = nil
        let urls = moodSourceURLs
        let name = petName
        let stripBG = removeBackground
        Task {
            do {
                let pack = try await viewModel.petAssetStore.importCustomPet(
                    name: name,
                    moodSourceURLs: urls,
                    removeBackground: stripBG
                )
                viewModel.selectPet(id: pack.id)
                viewModel.setFloatingHUDMode(.pet)
                if !viewModel.floatingHUDAlwaysOn && !viewModel.isMainWindowMinimized {
                    viewModel.floatingHUDAlwaysOn = true
                }
                isImporting = false
                dismiss()
            } catch {
                isImporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deletePack(_ pack: PetPack) {
        do {
            let wasActive = (viewModel.activePetID == pack.id)
            try viewModel.petAssetStore.deleteCustomPet(id: pack.id)
            if wasActive {
                viewModel.selectPet(id: PetPack.builtInWestieID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CheckerboardPattern: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            let rows = Int(ceil(size.height / tile))
            let cols = Int(ceil(size.width / tile))
            for r in 0..<rows {
                for c in 0..<cols {
                    let isLight = (r + c).isMultiple(of: 2)
                    let rect = CGRect(x: CGFloat(c) * tile, y: CGFloat(r) * tile, width: tile, height: tile)
                    context.fill(
                        Path(rect),
                        with: .color(isLight ? Color(white: 0.92) : Color(white: 0.83))
                    )
                }
            }
        }
    }
}
