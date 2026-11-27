import SwiftUI
import AppKit
import DiskGuardCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct DiskGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("DiskGuard") {
            MainView(viewModel: viewModel)
                .frame(minWidth: 880, minHeight: 600)
                .preferredColorScheme(preferredScheme)
        }
        .defaultSize(width: 1040, height: 720)
        .windowStyle(.hiddenTitleBar)
    }

    private var preferredScheme: ColorScheme? {
        switch viewModel.appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
