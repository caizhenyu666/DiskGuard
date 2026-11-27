import SwiftUI
import AppKit
import DiskGuardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var keepAliveInMenuBar: Bool = true
    var onReopenRequest: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !keepAliveInMenuBar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            onReopenRequest?()
        }
        return true
    }
}

@main
struct DiskGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let viewModel = AppViewModel()
    private let floatingController = FloatingMonitorController()
    @AppStorage("diskguard.showMenuBarExtra") private var showMenuBarExtra: Bool = true
    @AppStorage("diskguard.appearanceMode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    var body: some Scene {
        WindowGroup("DiskGuard", id: "main") {
            MainView(viewModel: viewModel, floatingController: floatingController)
                .frame(minWidth: 920, minHeight: 640)
                .preferredColorScheme(preferredScheme)
        }
        .defaultSize(width: 1060, height: 760)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra(isInserted: menuBarInsertedBinding) {
            MenuBarPopoverView(viewModel: viewModel, floatingController: floatingController)
                .preferredColorScheme(preferredScheme)
        } label: {
            MenuBarLabelView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarInsertedBinding: Binding<Bool> {
        Binding(
            get: { showMenuBarExtra },
            set: { newValue in
                guard newValue != showMenuBarExtra else { return }
                showMenuBarExtra = newValue
                if viewModel.showMenuBarExtra != newValue {
                    viewModel.showMenuBarExtra = newValue
                }
            }
        )
    }

    private var preferredScheme: ColorScheme? {
        switch AppearanceMode(rawValue: appearanceModeRaw) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
