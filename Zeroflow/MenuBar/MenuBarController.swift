import AppKit
import SwiftUI

extension Notification.Name {
    /// 请求打开设置窗口（如无截屏权限时引导授权）
    static let zeroflowOpenSettings = Notification.Name("zeroflow.openSettings")

    /// 请求打开设置窗口并跳到「灵动岛」标签页（面板空态引导按钮）
    static let zeroflowOpenNotchSettings = Notification.Name("zeroflow.openNotchSettings")
}

/// 菜单栏控制器：常驻菜单栏，提供「设置」与「退出」
final class MenuBarController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?

    private var settingsWindowController: NSWindowController?

    private var captureItem: NSMenuItem?

    private var updateItem: NSMenuItem?

    /// 菜单项上的 app 图标：画一次 32px 位图复用，别每次刷新都重绘
    private lazy var updateMenuIcon: NSImage? = AppIconCache.ownIcon(pointSize: 16)

    private var updateWindowController: NSWindowController?

    /// 已检测到但还没安装的新版；启动检测只把它显示在菜单项上，点开才看详情
    private var pendingRelease: UpdateChecker.Release?

    private var isCheckingUpdate = false

    private var isInstallingUpdate = false

    private var downloadProgress: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .zeroflowOpenSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .zeroflowOpenNotchSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenshotEnabledDidChange(_:)),
            name: GlobalHotkeyManager.screenshotEnabledDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: L10n.didChangeNotification,
            object: nil
        )
        // 屏幕配置变化（分辨率/显示接入）时让截图的 contentFilter 缓存失效重建
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            ScreenCapture.invalidateFilterCache()
        }

        GlobalHotkeyManager.shared.setTriggerHandler {
            CaptureCoordinator.shared.startCapture()
        }
        GlobalHotkeyManager.shared.reapply()
        SettingsStore.shared.reconcileLaunchAtLogin()

        // Dock 单击最小化：按开关初始状态启停（开关变化由 DockClickMinimizer 自行监听恢复）
        DockClickMinimizer.shared.reapply()

        // 鼠标滚轮方向翻转：按开关初始状态启停（开关变化由 MouseScrollReverser 自行监听恢复）
        MouseScrollReverser.shared.reapply()

        // 窗口切换器：按开关初始状态启停（开关变化由 CommandTabSwitcher 自行监听恢复）
        CommandTabSwitcher.shared.reapply()

        // Dock 悬停预览：按开关初始状态启停（开关变化由 DockHoverPreviewController 自行监听恢复）
        DockHoverPreviewController.shared.reapply()

        // 灵动岛刘海面板：按开关初始状态启停（开关变化由 NotchHotspotController 自行监听恢复）
        NotchHotspotController.shared.reapply()

        // 剪贴板历史：按开关初始状态启停监听与全局热键（开关变化由各自监听恢复）
        ClipboardMonitor.shared.reapply()
        ClipboardPanelController.shared.reapply()

        // 右键菜单扩展：不在这里做任何事。appex 只是注入器，起停与实例数全交给 pkd
        // （见 FinderSyncElection 的说明与 PITFALLS_DEV.md DEV-091）。

        if ProcessInfo.processInfo.environment["ZEROFLOW_AUTO_CAPTURE"] == "1" {
            ZSLog("env ZEROFLOW_AUTO_CAPTURE: defer 1.5s then capture")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CaptureCoordinator.shared.startCapture()
            }
        }
        if ProcessInfo.processInfo.environment["ZEROFLOW_EDITOR_DEBUG"] == "1" {
            ZSLog("env ZEROFLOW_EDITOR_DEBUG: defer 1.5s then open editor directly")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CaptureCoordinator.shared.openEditorForDebug()
            }
        }
        if ProcessInfo.processInfo.environment["ZEROFLOW_DOCK_PROBE"] == "1" {
            ZSLog("env ZEROFLOW_DOCK_PROBE: defer 1s then dump dock AX tree")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                DockClickMinimizer.runProbe()
            }
        }
        if ProcessInfo.processInfo.environment["ZEROFLOW_SWITCHER_DEBUG"] == "1" {
            ZSLog("env ZEROFLOW_SWITCHER_DEBUG: defer 1s then dump window list")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                CommandTabSwitcher.runDebugProbe()
            }
        }
        if ProcessInfo.processInfo.environment["ZEROFLOW_OPEN_SETTINGS"] == "1" {
            ZSLog("env ZEROFLOW_OPEN_SETTINGS: defer 1.5s then open settings window")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.openSettings()
            }
        }
        if let clipboardDebug = ProcessInfo.processInfo.environment["ZEROFLOW_CLIPBOARD_DEBUG"], clipboardDebug != "0" {
            let expand = clipboardDebug == "preview"
            ZSLog("env ZEROFLOW_CLIPBOARD_DEBUG=\(clipboardDebug): defer 1.5s then show clipboard panel, expand=\(expand)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                ClipboardPanelController.shared.showForDebug(expandAfter: expand ? 1 : 0)
            }
        }
        if let focusStr = ProcessInfo.processInfo.environment["ZEROFLOW_AUTO_FOCUS"],
           let wid = CGWindowID(exactly: Int(focusStr) ?? -1) {
            ZSLog("env ZEROFLOW_AUTO_FOCUS: defer 2s then focus wid=\(wid)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let w = WindowList.shared.enumerate().first(where: { $0.id == wid }) else {
                    ZSLog("AUTO_FOCUS: wid \(wid) not in enumerate list")
                    return
                }
                ZSLog("AUTO_FOCUS: focusing wid=\(wid) app=\(w.appName)")
                WindowActivator.shared.focus(window: w)
            }
        }

        // 内存探针 / 循环压测（默认关闭，见 MemoryProbe / MemoryCycleRunner）
        MemoryProbe.startIfNeeded()
        MemoryCycleRunner.startIfNeeded()

        // 启动完成后在后台异步检查一次更新：不阻塞启动、不定时、不节流，
        // 发现新版只改菜单项（不弹窗），点开才看详情（Debug 构建默认跳过）
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            UpdateChecker.shared.autoCheck { [weak self] release in
                self?.markUpdateAvailable(release)
            }
        }

        // 更新窗口排版核对：用超长说明直接打开详情窗口，验证滚动与菜单项图标
        if ProcessInfo.processInfo.environment["ZEROFLOW_UPDATE_WINDOW"] == "1" {
            ZSLog("env ZEROFLOW_UPDATE_WINDOW: defer 1.5s then show update window")
            let notes = (1...40)
                .map { "第 \($0) 条更新说明：修复了一些问题，调整了若干细节。" }
                .joined(separator: "\n")
            let fake = UpdateChecker.Release(
                version: "9.9.9",
                notes: notes,
                pageURL: URL(string: "https://github.com/hellolio/zeroflow/releases")!,
                assetURL: nil
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.markUpdateAvailable(fake)
                self?.showUpdateWindow(fake)
                // 离屏抓 contentView（不依赖屏幕录制权限），核对排版与滚动；
                // 固定浅色外观，否则深色模式下白字抓在透明底上等于看不见
                self?.updateWindowController?.window?.appearance = NSAppearance(named: .aqua)
                // 离屏抓 contentView（不依赖屏幕录制权限），核对排版与滚动
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard let window = self?.updateWindowController?.window,
                          let view = window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/zf-update-window.png"))
                        ZSLog("ZEROFLOW_UPDATE_WINDOW: snapshot written")
                    }
                }
            }
        }

        // 「一键清理」压测：ZEROFLOW_CLEAN_ON_LAUNCH=<秒> 延时自动跑一次（默认关闭）
        if let raw = ProcessInfo.processInfo.environment["ZEROFLOW_CLEAN_ON_LAUNCH"] {
            let delay = Double(raw) ?? 1.5
            ZSLog("env ZEROFLOW_CLEAN_ON_LAUNCH: defer \(delay)s then clean")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                CacheCleaner.shared.clean()
            }
        }
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "bolt.fill",
            accessibilityDescription: "zeroflow"
        )
        item.button?.imagePosition = .imageOnly
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()

        let captureItem = NSMenuItem(
            title: L10n.tr("立即截图（%@）", arguments: SettingsStore.shared.shortcut.displayString),
            action: #selector(startScreenshot), keyEquivalent: ""
        )
        captureItem.target = self
        captureItem.isEnabled = SettingsStore.shared.screenshotEnabled
        self.captureItem = captureItem
        menu.addItem(captureItem)

        let settingsItem = NSMenuItem(title: L10n.tr("设置…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        self.updateItem = updateItem
        menu.addItem(updateItem)
        refreshUpdateItem()

        let quitItem = NSMenuItem(title: L10n.tr("退出 zeroflow"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        settingsWindowController?.window?.title = L10n.tr("zeroflow 设置")
    }

    /// 菜单项状态统一在这里刷新：下载进度 / 检查中 / 已发现新版 / 待检查。
    private func refreshUpdateItem() {
        guard let item = updateItem else { return }
        if let progress = downloadProgress {
            item.title = L10n.tr("正在下载 %d%%", arguments: Int(progress * 100))
            item.image = nil
        } else if isCheckingUpdate {
            item.title = L10n.tr("正在检查…")
            item.image = nil
        } else if let release = pendingRelease {
            item.title = L10n.tr("发现新版本 %@", arguments: release.version)
            item.image = updateMenuIcon
        } else {
            item.title = L10n.tr("检查更新…")
            item.image = nil
        }
        item.isEnabled = !isCheckingUpdate && !isInstallingUpdate
    }

    @objc private func startScreenshot() {
        CaptureCoordinator.shared.startCapture()
    }

    @objc private func screenshotEnabledDidChange(_ notification: Notification) {
        let enabled = (notification.userInfo?["enabled"] as? Bool) ?? SettingsStore.shared.screenshotEnabled
        captureItem?.isEnabled = enabled
    }

    @objc private func languageDidChange() {
        rebuildMenu()
    }

    // MARK: - 更新

    @objc private func checkForUpdates() {
        guard !isCheckingUpdate, !isInstallingUpdate else { return }

        // 启动时已发现新版：直接看详情，不重复请求
        if let release = pendingRelease {
            showUpdateWindow(release)
            return
        }

        isCheckingUpdate = true
        refreshUpdateItem()

        UpdateChecker.shared.check { [weak self] result in
            guard let self else { return }
            self.isCheckingUpdate = false

            switch result {
            case .upToDate(let current):
                self.refreshUpdateItem()
                self.presentUpToDate(current: current)
            case .updateAvailable(let release):
                self.pendingRelease = release
                self.refreshUpdateItem()
                self.showUpdateWindow(release)
            case .failed:
                self.refreshUpdateItem()
                self.presentCheckFailure()
            }
        }
    }

    private func presentUpToDate(current: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("已是最新版本")
        alert.informativeText = L10n.tr("当前版本 %@ 已是最新。", arguments: current)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr("好的"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 启动检查发现新版：只改菜单项，不弹窗，等用户点开详情。
    private func markUpdateAvailable(_ release: UpdateChecker.Release) {
        pendingRelease = release
        refreshUpdateItem()
    }

    private func showUpdateWindow(_ release: UpdateChecker.Release) {
        guard !isInstallingUpdate else { return }
        if let existing = updateWindowController?.window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        closeUpdateWindow()

        let view = UpdateWindowView(
            release: release,
            onInstall: { [weak self] in
                self?.closeUpdateWindow()
                self?.startInstall(release)
            },
            onOpenPage: { [weak self] in
                self?.closeUpdateWindow()
                NSWorkspace.shared.open(release.pageURL)
            },
            onCancel: { [weak self] in
                self?.closeUpdateWindow()
            }
        )

        // 背景走统一的面板玻璃：macOS 26+ 原生液态玻璃，旧系统回退 .popover 磨砂。
        // 用无边框窗口：带 .titled + fullSizeContentView 时标题栏高度会算进 safeAreaInsets，
        // SwiftUI 内容被整体下推、底部按钮溢出被裁；无边框窗口没有标题栏，圆角由玻璃自绘。
        let container = PanelHostingContainer(rootView: view,
                                              glassBackground: true,
                                              cornerRadius: 12)
        let window = UpdateWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 412),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("软件更新")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.contentView = container
        // 内容按窗口圆角裁剪，避免分割线两端悬在玻璃圆角外的透明区域
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        updateWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeUpdateWindow() {
        updateWindowController?.close()
        updateWindowController = nil
    }

    private func startInstall(_ release: UpdateChecker.Release) {
        guard let assetURL = release.assetURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }

        isInstallingUpdate = true
        downloadProgress = 0
        refreshUpdateItem()

        UpdateInstaller.shared.install(from: assetURL, progress: { [weak self] value in
            guard let self else { return }
            self.downloadProgress = value
            self.refreshUpdateItem()
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // 替换脚本已在等待本进程退出，退出后由脚本覆盖并重启
                NSApp.terminate(nil)
            case .failure(let error):
                self.isInstallingUpdate = false
                self.downloadProgress = nil
                self.refreshUpdateItem()
                self.presentInstallFailure(error, pageURL: release.pageURL)
            }
        })
    }

    private func presentInstallFailure(_ error: Error, pageURL: URL) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("更新失败")
        alert.alertStyle = .warning

        if case UpdateInstaller.InstallError.notWritable(let dmg) = error {
            alert.informativeText = L10n.tr("无法写入应用所在目录，安装包已保留，请手动拖入「应用程序」文件夹。")
            alert.addButton(withTitle: L10n.tr("打开安装包"))
            alert.addButton(withTitle: L10n.tr("稍后"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(dmg)
            }
            return
        }

        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.tr("打开下载页"))
        alert.addButton(withTitle: L10n.tr("取消"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(pageURL)
        }
    }

    private func presentCheckFailure() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("检查更新失败")
        alert.informativeText = L10n.tr("无法连接更新服务器，请稍后重试。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("好的"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView())
            )
            window.title = L10n.tr("zeroflow 设置")
            window.setContentSize(NSSize(width: 860, height: 640))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关窗即释放设置窗口及其 9 个标签页的 SwiftUI 视图树；下次打开重新创建。
    /// 延后一拍再置 nil，避免在 AppKit 的关窗回调里同步释放窗口自身。
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            guard let self, self.settingsWindowController?.window === closing else { return }
            self.settingsWindowController = nil
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// 无边框更新窗口：borderless 默认不能成为 key window，收不到 Esc / Return 快捷键。
private final class UpdateWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}