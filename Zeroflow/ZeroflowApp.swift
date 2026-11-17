import SwiftUI
import AppKit

@main
struct ZeroflowMain {
    static func main() {
        let app = NSApplication.shared
        let controller = MenuBarController()
        app.delegate = controller
        // 预热 CGS/WindowServer 连接：不先建立连接时 SkyLight SLPS 调用会静默 no-op（err=0 但无效果）
        _ = CGSWindowServer.shared.isAvailable
        // 辅助功能权限缓存：从系统设置返回时立即复核
        AccessibilityPermission.startObserving()
        // 调试开关：主动弹「辅助功能」「屏幕录制」两个系统授权窗（ZEROFLOW_REQUEST_PERMISSIONS=1）
        if ProcessInfo.processInfo.environment["ZEROFLOW_REQUEST_PERMISSIONS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AccessibilityPermission.requestAuthorization()
                ScreenRecordingPermission.requestAuthorization()
            }
        }
        // 消化 Finder 扩展转交的「访达自定义命令」（见 Services/FinderCommandRunner.swift）
        FinderCommandRunner.shared.start()
        app.run()
    }
}

#Preview {
    SettingsView()
}