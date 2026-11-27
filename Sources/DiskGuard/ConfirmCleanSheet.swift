import SwiftUI
import DiskGuardCore

struct ConfirmCleanSheet: View {
    let items: [ScanItem]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    private var cautionItems: [ScanItem] {
        items.filter { $0.tier == .caution }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 3) {
                    Text("确认移入废纸篓（随时可在访达恢复）")
                        .font(.system(size: 16, weight: .semibold))
                    Text("共 \(items.count) 个项目，合计 \(DiskByteFormatter.string(from: totalBytes))。DiskGuard 绝不直接永久删除文件。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if !cautionItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("包含 \(cautionItems.count) 项「需确认」开发残留，请再次核对具体路径：")
                            .font(.system(size: 12.5, weight: .semibold))
                    }

                    ForEach(cautionItems) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(item.title)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(DiskByteFormatter.string(from: item.sizeBytes))
                                    .font(.system(size: 12).monospacedDigit())
                            }
                            Text(item.displayPathURL.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("本次清理清单")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.categoryIcon)
                                    .font(.system(size: 12))
                                    .foregroundStyle(item.tier == .caution ? .orange : .green)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                    Text(DiskByteFormatter.compactPath(item.displayPathURL))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                Text(DiskByteFormatter.string(from: item.sizeBytes))
                                    .font(.system(size: 12).monospacedDigit())
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 210)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            HStack {
                Text("提示：移入废纸篓后，需在访达手动「清倒废纸篓」才释放物理空间")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("移至废纸篓 (\(DiskByteFormatter.string(from: totalBytes)))") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}
