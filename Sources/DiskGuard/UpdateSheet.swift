import SwiftUI
import AppKit
import DiskGuardCore

struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AppViewModel

    private var activeRelease: ReleaseInfo? {
        switch viewModel.updateState {
        case .available(let release), .downloading(let release, _):
            return release
        default:
            return nil
        }
    }

    private var isDownloading: Bool {
        if case .downloading = viewModel.updateState { return true }
        return false
    }

    private var downloadStatusText: String? {
        if case .downloading(_, let message) = viewModel.updateState { return message }
        return nil
    }

    private var errorText: String? {
        if case .failed(let message) = viewModel.updateState { return message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.green.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(activeRelease != nil ? "发现 DiskGuard 新版本" : "软件更新")
                        .font(.system(size: 16, weight: .semibold))
                    HStack(spacing: 6) {
                        Text("当前版本 \(viewModel.currentVersion.displayTag) (Build \(viewModel.currentBuildNumber))")
                        if let release = activeRelease {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10))
                            Text(release.tagName)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            if let release = activeRelease {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(release.title)
                            .font(.system(size: 13.5, weight: .semibold))
                        Spacer()
                        Text(release.assetName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    ScrollView {
                        Text(release.notes.isEmpty ? "暂无详细更新日志。" : release.notes)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 150)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }

            if let status = downloadStatusText {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let errorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorText)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if !AppUpdater.isRunningFromAppBundle() {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("当前以开发模式运行（非 .app 包），自动覆盖重启仅在从 DiskGuard.app 启动时可用。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if let url = activeRelease?.htmlURL {
                    Button("查看发布页") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("稍后再说") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isDownloading)

                if let release = activeRelease {
                    Button("立即更新并重启") {
                        viewModel.performUpdate(release)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isDownloading || !AppUpdater.isRunningFromAppBundle())
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
