import AppKit
import SwiftUI

@main
struct TrafficMonitorApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: TrafficMonitorAppDelegate

    var body: some Scene {
        WindowGroup("流量监控", id: "dashboard") {
            DashboardSceneRoot(
                store: appDelegate.store,
                statusBarController: appDelegate.statusBarController
            )
        }
        .defaultSize(width: 1_080, height: 760)
        .windowToolbarStyle(.unified)
    }
}

private struct DashboardSceneRoot: View {
    @ObservedObject var store: TrafficMonitorStore
    let statusBarController: MenuBarStatusController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DashboardView(store: store, statusBarController: statusBarController)
            .frame(minWidth: 860, minHeight: 600)
            .onAppear {
                store.start()
                statusBarController.openDashboard = {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

@MainActor
final class TrafficMonitorAppDelegate: NSObject, NSApplicationDelegate {
    let store = TrafficMonitorStore()
    let statusBarController = MenuBarStatusController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 是否在 Dock 显示图标，由偏好控制（默认显示）。
        // info.plist 里为纯菜单栏（LSUIElement=YES），这里运行时切换为 .regular 即可让 App 出现在 Dock。
        Self.applyDockIconPreference(activate: true)

        store.start()
        statusBarController.install(store: store)

        // 监听偏好变化：Dock 图标 / 菜单栏图标开关即时生效。
        // 注意：只有当相关偏好真正变化时才处理，且绝不主动激活到前台。
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let showDock = UserDefaults.standard
                    .object(forKey: PreferenceKey.showDockIcon) as? Bool ?? true
                if showDock != Self.lastDockVisibility {
                    Self.applyDockIconPreference(activate: false)
                }
                let showMenuBar = UserDefaults.standard
                    .object(forKey: PreferenceKey.showMenuBarIcon) as? Bool ?? true
                if showMenuBar != self.statusBarController.isMenuBarVisible {
                    self.statusBarController.setMenuBarVisible(showMenuBar)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        statusBarController.remove()
    }

    private static var lastDockVisibility: Bool {
        get { UserDefaults.standard.object(forKey: "lastAppliedDockVisibility") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lastAppliedDockVisibility") }
    }

    /// 根据偏好设置 Dock 图标显示。
    /// - `PreferenceKey.showDockIcon` 默认 `true`：Dock 与菜单栏同时存在。
    /// - 设为 `false`：仅菜单栏常驻（等价于 LSUIElement）。
    /// - `activate`：仅 App 启动时传 true 拉一次焦点；之后切换 Dock 图标绝不抢前台。
    static func applyDockIconPreference(activate: Bool = false) {
        let showInDock = UserDefaults.standard.object(forKey: PreferenceKey.showDockIcon) as? Bool ?? true
        lastDockVisibility = showInDock
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        if activate, showInDock {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
