import AppKit
import Combine
import QuartzCore
import SwiftUI

/// 剪贴板历史面板：非激活 NSPanel（`.nonactivatingPanel` + `canBecomeKey = true`），
/// 成为 key window 即可收键盘，但不激活本 app（原前台应用保持不动，粘贴时 ⌘V 直接落到原窗口）。
/// 键盘（↑↓ / ↵ / esc）由本地 keyDown monitor 拦截，搜索输入交给 SwiftUI 的 TextField。
final class ClipboardPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0,
                                       width: ClipboardPanelMetrics.listWidth,
                                       height: ClipboardPanelMetrics.height(for: 1)),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

/// 剪贴板历史面板控制器：热键触发 → 鼠标位置弹出 → 选择/搜索 → 复制并粘贴回原窗口。
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPanelController()

    private enum PreviewSide {
        case left
        case right
    }

    private var panel: ClipboardPanel?
    private var model: ClipboardViewModel?
    /// SwiftUI 内容宿主：定宽 `expandedWidth`，按预览方向钉在窗口左边缘或右边缘（DEV-068）
    private weak var hostingView: NSView?
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var pendingPreview: DispatchWorkItem?
    private var isDismissing = false
    /// 上一次真正生效的搜索词，用来滤掉视图挂载时的空回写
    private var lastQuery = ""

    /// 面板左上角锚点（Cocoa 全局坐标）：列表列固定贴在这里，展开预览时窗口只向一侧长
    private var anchorTopY: CGFloat = 0
    private var baseX: CGFloat = 0
    private var anchorScreen: NSScreen?
    private var previewSide: PreviewSide = .right

    /// 面板弹出前的原前台应用：仅在触发兜底激活（面板拿不到 key）时用于还原焦点
    private var previousApp: NSRunningApplication?
    private var didActivateApp = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnabledDidChange),
            name: ClipboardMonitor.didChangeNotification,
            object: nil
        )
    }

    /// 启动时 / 开关变化时调用：挂上热键触发回调并按开关注册热键
    func reapply() {
        GlobalHotkeyManager.shared.setClipboardTriggerHandler { [weak self] in
            self?.toggle()
        }
        GlobalHotkeyManager.shared.reapplyClipboard()
        if !SettingsStore.shared.clipboardEnabled {
            dismiss()
        }
    }

    @objc private func handleEnabledDidChange() {
        reapply()
    }

    // MARK: - 弹出 / 收起

    private func toggle() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            show()
        }
    }

    /// 调试入口：忽略开关直接弹出（`ZEROFLOW_CLIPBOARD_DEBUG=1`），`expandAfter > 0` 时再自动展开首条预览
    func showForDebug(expandAfter delay: TimeInterval = 0) {
        show(force: true)
        // `ZEROFLOW_PANEL_SNAPSHOT=<dir>`：把面板内容离屏抓成 PNG，用于无法截屏的环境下核对排版
        if let dir = ProcessInfo.processInfo.environment["ZEROFLOW_PANEL_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.debugSnapshot("\(dir)/collapsed.png")
            }
        }
        guard delay > 0 else { return }
        // show() 里已为首条起了停留计时，这里接管，避免两条路径各展开一次
        pendingPreview?.cancel()
        pendingPreview = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let model = self.model, let item = model.filteredItems.first else { return }
            self.expandPreview(with: item)
            if let dir = ProcessInfo.processInfo.environment["ZEROFLOW_PANEL_SNAPSHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.debugSnapshot("\(dir)/expanded.png")
                }
            }
        }
    }

    private func show(force: Bool = false) {
        guard force || SettingsStore.shared.clipboardEnabled else { return }
        guard let panel = ensurePanel() else { return }

        previousApp = NSWorkspace.shared.frontmostApplication
        didActivateApp = false

        let model = ClipboardViewModel(items: ClipboardHistoryStore.shared.items)
        self.model = model
        observe(model)
        installContent(model)
        positionNearMouse()

        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        // 兜底：若系统没把 key 交给非激活面板（异常/旧系统），临时激活本 app 收键盘，
        // 粘贴/收面板时再还原原应用焦点
        if !panel.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            didActivateApp = true
        }
        // 弹出即选中第一条：也要为它起停留计时，否则只有 ↑↓ 或悬停到别的行才会展开预览
        schedulePreview()
        ZSLog("clipboard panel shown, items=\(model.items.count), key=\(panel.isKeyWindow)")
    }

    func dismiss() {
        pendingPreview?.cancel()
        pendingPreview = nil
        guard let panel, panel.isVisible, !isDismissing else { return }
        isDismissing = true
        panel.orderOut(nil)
        // 释放 SwiftUI 内容树与液态玻璃背景；下次弹出由 show() 重建
        panel.contentView = nil
        model = nil
        // 关窗即丢解码后的缩略图/预览位图，不留常驻（面板再开时按需重新读小文件）
        ClipboardHistoryStore.shared.purgeMemoryCaches()
        isDismissing = false
        cancellables.removeAll()
        if MemoryProbe.isEnabled { MemoryProbe.log("clipboard-dismiss") }
        ZSLog("clipboard panel dismissed")
        if didActivateApp {
            didActivateApp = false
            previousApp?.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isDismissing else { return }
        ZSLog("clipboard panel resigned key -> dismiss")
        dismiss()
    }

    // MARK: - 选择 / 预览

    private func observe(_ model: ClipboardViewModel) {
        cancellables.removeAll()
        lastQuery = model.query
        model.$query
            .dropFirst()
            .sink { [weak self] query in
                // 面板挂载时 TextField 会把空查询原样回写一次：值没变就不是用户输入，
                // 不能打断弹出时为首条起的预览计时
                guard let self, query != self.lastQuery else { return }
                self.lastQuery = query
                self.handleQueryChange()
            }
            .store(in: &cancellables)
        // 历史在后台加载：面板若先弹出（items 还是空），加载完成后补进模型
        ClipboardHistoryStore.shared.$items
            .dropFirst()
            .sink { [weak self] items in
                guard let self, self.model === model else { return }
                let wasEmpty = model.items.isEmpty
                guard wasEmpty || model.items.map(\.id) != items.map(\.id) else { return }
                let oldRowCount = ClipboardPanelMetrics.rows(for: model.filteredItems.count)
                model.items = items
                model.selectedIndex = min(model.selectedIndex, max(0, model.filteredItems.count - 1))
                if let preview = model.previewItem, !items.contains(where: { $0.id == preview.id }) {
                    model.previewItem = nil
                }
                // 行数变了（删除/清空/后台加载完成）必须重新落 frame，
                // 否则面板会留着被删掉那条的高度，底部空出一截
                let newRowCount = ClipboardPanelMetrics.rows(for: model.filteredItems.count)
                if wasEmpty || newRowCount != oldRowCount {
                    // 后台加载完成没有用户动作，无动画落位；删除/清空走收缩动画
                    self.applyFrame(animated: !wasEmpty)
                }
                // 只给「弹出时历史还没加载完」补一次首条预览计时。
                // 删除后不主动展开新条目：否则收缩动画会立刻被重展开打断，看着像抽搐
                if wasEmpty, model.previewItem == nil, model.query.isEmpty { self.schedulePreview() }
            }
            .store(in: &cancellables)
    }

    private func handleQueryChange() {
        guard let model else { return }
        ZSLog("clipboard: query changed, len=\(model.query.count)")
        model.selectedIndex = 0
        model.selectionFromPointer = false
        // 搜索变化只重算列表，不自动展开预览：展开必须由用户停留/移动选择触发
        pendingPreview?.cancel()
        pendingPreview = nil
        let wasPreviewing = model.previewItem != nil
        if wasPreviewing {
            model.previewItem = nil
        }
        applyFrame(animated: wasPreviewing)
    }

    private func hover(_ index: Int) {
        guard let model else { return }
        guard index != model.selectedIndex else {
            // 悬停在「已选中但还没展开」的行（如刚弹出时的第一条）同样要起计时
            if model.previewItem == nil, pendingPreview == nil { schedulePreview() }
            return
        }
        ZSLog("clipboard: hover row \(index)")
        model.selectionFromPointer = true
        model.selectedIndex = index
        schedulePreview()
    }

    private func select(_ index: Int) {
        guard let model else { return }
        model.selectedIndex = index
        pasteSelected()
    }

    // MARK: - 删除

    /// 删除单条：Store 落盘 + 清图片文件，面板高度由 `$items` 订阅统一 refit
    private func delete(_ item: ClipboardItem) {
        guard let model, model.items.contains(where: { $0.id == item.id }) else { return }
        pendingPreview?.cancel()
        pendingPreview = nil
        // 先收掉预览再删：被删项正在预览时，留一帧旧内容会闪
        if model.previewItem?.id == item.id { model.previewItem = nil }
        ClipboardHistoryStore.shared.remove(id: item.id)
        ZSLog("clipboard: deleted item, remaining=\(ClipboardHistoryStore.shared.items.count)")
    }

    private func deleteSelected() {
        guard let model, let item = model.selectedItem else { return }
        delete(item)
    }

    private func clearAll() {
        pendingPreview?.cancel()
        pendingPreview = nil
        model?.previewItem = nil
        ClipboardHistoryStore.shared.clear()
        ZSLog("clipboard: cleared all")
    }

    private func moveSelection(by step: Int) {
        guard let model else { return }
        let count = model.filteredItems.count
        guard count > 0 else { return }
        model.selectionFromPointer = false
        model.selectedIndex = (model.selectedIndex + step + count) % count
        schedulePreview()
    }

    /// 停留计时：未展开时到点展开；已展开时立即换成当前选中项的内容（不再重复等）
    private func schedulePreview() {
        pendingPreview?.cancel()
        pendingPreview = nil
        guard let panel, panel.isVisible, let model else { return }
        guard let item = model.selectedItem else {
            if model.previewItem != nil {
                model.previewItem = nil
                applyFrame(animated: true)
            }
            return
        }
        if model.previewItem != nil {
            if model.previewItem?.id != item.id { model.previewItem = item }
            return
        }
        let expectedID = item.id
        let delay = max(200, SettingsStore.shared.clipboardPreviewDelayMs)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let model = self.model, panel.isVisible,
                  model.selectedItem?.id == expectedID else { return }
            self.expandPreview(with: item)
        }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000, execute: work)
    }

    /// 展开预览：先把内容布局+绘制完，再让窗口生长。
    /// 顺序反了的话窗口先变宽、内容后画，中间那几帧窗口显示的是被横向拉伸的旧内容（DEV-068）
    private func expandPreview(with item: ClipboardItem) {
        guard let panel, let model else { return }
        // 幂等：同一项已经设过 previewItem（展开在途或已完成）就不再触发第二次，
        // 否则两条入口（停留计时 / 调试入口）会让窗口动画被重新起手
        if model.previewItem?.id == item.id { return }
        // 先定布局方向再出内容：一次求值就排好，避免「先右后左」两阶段重排
        previewSide = hasSpaceOnRight ? .right : .left
        let onLeft = previewSide == .left
        if model.previewOnLeft != onLeft { model.previewOnLeft = onLeft }
        // 钉法必须跟布局方向一起在预渲染之前就位，否则预渲染画的是「方向已换、内容还钉在旧边」的中间态
        pinHosting(toLeftSide: onLeft)
        model.previewItem = item
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible,
                  self.model?.previewItem?.id == item.id else { return }
            // 预渲染必须发生在窗口起手之前：窗口服务一旦开始生长，主线程就只剩每帧十几毫秒的预算
            let t0 = CACurrentMediaTime()
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.contentView?.displayIfNeeded()
            let prerender = (CACurrentMediaTime() - t0) * 1000
            self.applyFrame(animated: true)
            ZSLog(String(format: "preview prerender %.2fms, win=%.0fx%.0f",
                         prerender, panel.frame.width, panel.frame.height))
        }
    }

    // MARK: - 键盘

    /// 把面板内容离屏抓成 PNG（`ZEROFLOW_PANEL_SNAPSHOT=<dir>`，用于无法截屏的环境核对排版）
    private func debugSnapshot(_ path: String) {
        guard let view = panel?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        ZSLog("snapshot -> \(path) bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }

    private func installKeyMonitorOnce() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible, event.window === panel else {
                return event
            }
            switch event.keyCode {
            case 53: // esc
                self.dismiss()
                return nil
            case 125: // ↓
                self.moveSelection(by: 1)
                return nil
            case 126: // ↑
                self.moveSelection(by: -1)
                return nil
            case 36, 76: // return / enter
                self.pasteSelected()
                return nil
            case 51, 117: // delete / forward delete
                // 搜索框有内容时 Delete 该删字符，交还给 TextField；
                // 此时要删记录用 ⌘⌫（带 command 一律当删除记录处理）
                let deleteItem = event.modifierFlags.contains(.command)
                    || (self.model?.query.isEmpty ?? true)
                guard deleteItem else { return event }
                self.deleteSelected()
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - 粘贴

    private func pasteSelected() {
        guard let model, let item = model.selectedItem else { return }
        ZSLog("clipboard paste: kind=\(item.kind.rawValue), bytes=\(item.byteCount)")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text, forType: .string)
        case .image:
            guard let data = ClipboardHistoryStore.shared.pngData(for: item),
                  let image = NSImage(data: data) else {
                ZSLog("clipboard: image unavailable for paste")
                return
            }
            pasteboard.writeObjects([image])
        }
        // 自己写入的剪贴板不记入历史
        ClipboardMonitor.shared.markCurrentChangeCountAsHandled()

        let canPaste = AccessibilityPermission.isGranted
        dismiss()
        guard canPaste else {
            ZSLog("clipboard: copied only (no accessibility permission)")
            return
        }
        // 等面板真正收起、原窗口重新拿到 key 后再注入 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.postCommandV()
        }
    }

    /// 合成 ⌘V（需要辅助功能权限）；原应用自始至终是前台，按键直接落到原输入框
    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyV = CGKeyCode(9)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    // MARK: - 布局

    private var hasSpaceOnRight: Bool {
        guard let screen = anchorScreen else { return true }
        let needed = baseX + ClipboardPanelMetrics.expandedWidth + 8
        return needed <= screen.visibleFrame.maxX
    }

    private func collapsedSize(rowCount: Int) -> NSSize {
        NSSize(width: ClipboardPanelMetrics.listWidth,
               height: ClipboardPanelMetrics.height(for: rowCount))
    }

    /// 锚点：鼠标右下 12pt 弹出；右侧/下方放不下时翻到光标另一侧，避免面板压住光标
    private func positionNearMouse() {
        guard let panel, let model else { return }
        let size = collapsedSize(rowCount: model.filteredItems.count)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        anchorScreen = screen
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 8
        let offset: CGFloat = 12

        var x = mouse.x + offset
        if x + size.width > visible.maxX - gap {
            // 右侧放不下：翻到光标左侧
            x = mouse.x - offset - size.width
        }
        var topY = mouse.y - offset
        if topY - size.height < visible.minY + gap {
            // 下方放不下：翻到光标上方
            topY = mouse.y + offset + size.height
        }
        x = min(max(x, visible.minX + gap), max(visible.minX + gap, visible.maxX - size.width - gap))
        topY = min(max(topY, visible.minY + size.height + gap), visible.maxY - gap)
        baseX = x
        anchorTopY = topY
        previewSide = hasSpaceOnRight ? .right : .left
        ZSLog("clipboard: anchor mouse=\(Int(mouse.x)),\(Int(mouse.y)) -> x=\(Int(x)) top=\(Int(topY))")
        panel.setFrame(NSRect(x: x, y: topY - size.height, width: size.width, height: size.height),
                       display: false)
    }

    private func applyFrame(animated: Bool) {
        guard let panel, let model else { return }
        let visible = anchorScreen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var height = ClipboardPanelMetrics.height(for: model.filteredItems.count)
        height = min(height, visible.height - 16)
        let previewing = model.previewItem != nil
        // 预览在左时内容要右对齐钉住（见 pinHosting），收起态保持上次的方向即可：
        // 两种布局下列表都正好铺满 360 宽窗口，保持不动能省掉「收起后再切一次布局」的跳变（DEV-068）
        let onLeft = previewing ? (previewSide == .left) : model.previewOnLeft
        if model.previewOnLeft != onLeft { model.previewOnLeft = onLeft }
        pinHosting(toLeftSide: onLeft)
        let width = previewing ? ClipboardPanelMetrics.expandedWidth : ClipboardPanelMetrics.listWidth

        var x = baseX
        if previewing, previewSide == .left {
            x = baseX - ClipboardPanelMetrics.previewWidth - ClipboardPanelMetrics.dividerWidth
        }
        x = min(max(x, visible.minX + 8), max(visible.minX + 8, visible.maxX - width - 8))
        var y = anchorTopY - height
        y = min(max(y, visible.minY + 8), max(visible.minY + 8, visible.maxY - height - 8))

        let frame = NSRect(x: x, y: y, width: width, height: height)
        ZSLog("clipboard: frame -> x=\(Int(x)) top=\(Int(y + height)) \(Int(width))x\(Int(height)) preview=\(previewing) side=\(previewSide) animated=\(animated)")
        // 两个方向都走生长动画：内容已钉在「不动的那个边」上，窗口朝哪边长，另一边就是抽出来的抽屉
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// 把定宽内容钉在窗口的「不动边」上，让窗口生长时列表原地不动、预览像抽屉一样抽出来：
    /// - 预览在右 → 钉左边缘（内容局部 0 是列表，右侧 461pt 是预览），窗口向右长；
    /// - 预览在左 → 钉右边缘（内容局部 461 起是列表，左侧 460pt 是预览），窗口向左长。
    /// 收起态（窗口 360 宽）两种钉法下列表都正好铺满窗口，所以切换钉法本身不产生视觉跳变（DEV-068）
    private func pinHosting(toLeftSide: Bool) {
        guard let container = panel?.contentView, let hosting = hostingView else { return }
        let targetX = toLeftSide ? container.bounds.width - ClipboardPanelMetrics.expandedWidth : 0
        let mask: NSView.AutoresizingMask = toLeftSide ? [.minXMargin, .height] : [.height]
        if hosting.autoresizingMask != mask { hosting.autoresizingMask = mask }
        if abs(hosting.frame.origin.x - targetX) > 0.5 {
            hosting.setFrameOrigin(NSPoint(x: targetX, y: 0))
        }
    }

    // MARK: - 面板与内容

    private func ensurePanel() -> ClipboardPanel? {
        if let panel { return panel }
        let panel = ClipboardPanel()
        panel.delegate = self
        self.panel = panel
        installKeyMonitorOnce()
        return panel
    }

    private func installContent(_ model: ClipboardViewModel) {
        guard let panel else { return }
        let root = ClipboardPanelView(
            model: model,
            onSelect: { [weak self] index in self?.select(index) },
            onHover: { [weak self] index in self?.hover(index) },
            onDelete: { [weak self] item in self?.delete(item) },
            onClear: { [weak self] in self?.clearAll() }
        )
        let size = collapsedSize(rowCount: model.filteredItems.count)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        // 圆角在宿主 layer 上裁：内容恒定 821 宽，收起态窗口只有 360，把圆角画在内容上会跑到窗口外，
        // 右边缘变直角；裁在宿主上则任何宽度都贴着窗口边缘。顺带把遮罩从 821 宽的 SwiftUI 视图上摘掉（DEV-068）
        container.wantsLayer = true
        container.layer?.cornerRadius = ClipboardPanelMetrics.cornerRadius
        container.layer?.masksToBounds = true
        let background = makeBackground(size: size)
        container.addSubview(background)
        let hosting = NSHostingView(rootView: root)
        // hosting 固定成展开态宽度、只让高度跟随宿主：
        // 跟随窗口宽度的话，收起态（360）的 layer backing store 也只有 360 宽，右侧 461pt 的预览列
        // 压根没被光栅化；窗口生长时得靠主线程逐帧补画，主线程一停顿窗口服务就把旧内容横向拉伸，
        // 也就是那个"有概率闪一下"。定宽 821 则预览列在动画起手前就已经画完，生长纯粹是"揭开"（DEV-068）
        hosting.frame = NSRect(x: 0, y: 0, width: ClipboardPanelMetrics.expandedWidth, height: size.height)
        hosting.autoresizingMask = [.height]
        // hosting 必须靠 autoresizing 跟随宿主：挂 glass.contentView 或用约束会反向钳死窗口尺寸（DEV-024）
        // 超宽部分由窗口自身裁掉，宿主 layer 默认不 masksToBounds
        container.addSubview(hosting)
        hostingView = hosting
        panel.contentView = container
        panel.setContentSize(size)
        ZSLog("clipboard content installed: window=\(Int(size.width))x\(Int(size.height)) hosting=\(Int(hosting.frame.width))x\(Int(hosting.frame.height))")
    }

    /// 背景：macOS 26+ 原生液态玻璃（样式与系统一致，跟随外观/降低透明度），旧系统回退磨砂
    private func makeBackground(size: NSSize) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]

        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.style = .regular
            glass.cornerRadius = ClipboardPanelMetrics.cornerRadius
            glass.autoresizingMask = [.width, .height]
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: container.bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = ClipboardPanelMetrics.cornerRadius
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]
            backdrop = effect
        }
        container.addSubview(backdrop)
        return container
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
