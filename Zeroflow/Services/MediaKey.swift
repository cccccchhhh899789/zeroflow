import AppKit
import ApplicationServices

/// 系统媒体键注入（`NX_SYSDEFINED` 事件）。
///
/// 为什么需要它：QQ音乐、语音备忘录这类 app 不向 `MPNowPlayingInfoCenter` 上报，
/// `MRMediaRemoteSendCommand` 对它们无效（实测 `localPlaybackState` 纹丝不动），
/// 但系统媒体键走 MediaRemote 的 command 分发，能到达**当前的 now playing owner**。
///
/// 关键前提：目标 app 必须就是 owner。owner 被别的 app 占着时（实测 Chrome 空闲后
/// 仍挂着会话），媒体键会被那个 app 吃掉，目标 app 完全收不到。所以
/// `NowPlayingMonitor` 的展示对象**就是 owner**（DEV-090），`send()` 发送前还会用子进程
/// 再核一次 owner，不一致就不发——否则会误控别的 app。
enum MediaKey {
    static let playPause: Int32 = 16   // NX_KEYTYPE_PLAY
    static let next: Int32 = 17        // NX_KEYTYPE_NEXT
    static let previous: Int32 = 18    // NX_KEYTYPE_PREVIOUS

    /// 按下与抬起之间的间隔。
    ///
    /// **必须留**：紧贴着连发 down/up，系统会把整个事件当无效点击丢掉——实测 Safari
    /// 网页音频（`playbackRate` 1→1，纹丝不动），隔 30ms 再抬就是 1→0。这曾经让
    /// mediaKey 通道看起来「装了但从来没生效」（QQ音乐那路也一样，见 DEV-093）。
    private static let holdMicros: useconds_t = 30_000

    /// 串行队列：连点时保证 down/up 严格成对，不会交错成 down,down,up,up
    private static let queue = DispatchQueue(label: "com.zeroflow.mediakey")

    static func post(_ key: Int32) {
        queue.async {
            send(key, down: true)
            usleep(holdMicros)
            send(key, down: false)
        }
    }

    private static func send(_ key: Int32, down: Bool) {
        let flag: Int = down ? 0xa00 : 0xb00
        let data1 = Int(key) << 16 | (down ? 0xa : 0xb) << 8
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flag)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ), let cgEvent = event.cgEvent else { return }
        cgEvent.post(tap: .cghidEventTap)
    }
}

/// 网页播放器的播放/暂停控制：**点页面里的按钮**，不走媒体键。
///
/// 为什么需要：B站这类页面自己的播放态会跟 MediaRemote 抢——发媒体键过去，它暂停一下
/// 又被自己的逻辑顶回播放（实测点击「暂停」= 短暂暂停后恢复）；`MRMediaRemoteSendCommand`
/// 对 Safari 网页媒体更是完全无效。而直接 AX 按下页面上的「播放/暂停」按钮是**真实用户操作**，
/// 页面不会跟自己顶，实测 rate 1→0 且稳定保持。
///
/// 找不到按钮（原生 `<audio>`、纯 canvas 播放器）返回 false，由调用方退回媒体键。
/// **AX 调用一律在后台队列**，主线程碰 AX 会卡死（DEV-083）。
enum WebPlayerControl {
    /// 切换型按钮（按一下翻转，不看当前状态）
    private static let toggleTitles = ["播放/暂停", "播放或暂停", "Play/Pause", "Play or pause"]
    private static let playTitles = ["播放", "Play"]
    private static let pauseTitles = ["暂停", "Pause"]

    /// 按页面里的播放/暂停按钮。返回 false = 没找到可点的按钮
    static func pressPlayPause(pid: pid_t, toPlaying: Bool) -> Bool {
        guard pid > 0 else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        // **只搜焦点窗口**：整个 app 的树里包含后台标签页，多个视频页时很容易按错
        // 别人家的按钮（实测：当前播的是原生音频，却按到了后台 B站 标签页的按钮）。
        // 焦点窗口里没有按钮就老实退回媒体键
        let root = element(app, kAXFocusedWindowAttribute) ?? app
        guard let button = findButton(in: root, toPlaying: toPlaying) else {
            if NowPlayingMonitor.debug { ZSLog("WebPlayer: 没找到播放按钮，退回媒体键") }
            return false
        }
        let ok = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        if NowPlayingMonitor.debug {
            ZSLog("WebPlayer: AX 按下「\(title(of: button) ?? "?")」ok=\(ok)")
        }
        return ok
    }

    /// 深度优先找按钮。节点数设上限——Safari 的网页 AX 树动辄上万节点，
    /// 无上限遍历会把点击拖到几百毫秒
    private static func findButton(in root: AXUIElement, toPlaying: Bool) -> AXUIElement? {
        var budget = 6000
        var directional: AXUIElement?
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast() {
            guard budget > 0 else { break }
            budget -= 1
            guard depth < 60 else { continue }
            if role(of: element) == "AXButton" {
                let name = title(of: element) ?? description(of: element) ?? ""
                if toggleTitles.contains(where: { name.contains($0) }) { return element }
                if directional == nil {
                    let wants = toPlaying ? playTitles : pauseTitles
                    if wants.contains(name) { directional = element }
                }
            }
            for child in children(of: element) { stack.append((child, depth + 1)) }
        }
        return directional
    }

    private static func role(of element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }
    private static func title(of element: AXUIElement) -> String? { string(element, kAXTitleAttribute) }
    private static func description(of element: AXUIElement) -> String? { string(element, kAXDescriptionAttribute) }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }
}

/// 从 app 的 AX 树里读曲目信息（不上报 Now Playing 的 app 唯一可靠的元数据来源）。
///
/// 实测 QQ音乐把整条播放控制栏暴露成自绘 `AXUnknown` 节点（没有 AX action，点不了），
/// 但 `AXDescription` 里有完整曲目：`歌曲名：虚拟 - 歌手名：陈粒`。
/// 比读窗口标题可靠得多——窗口关掉/最小化就没标题，而播放控制栏在播放时一直存在。
enum AXMediaInfoReader {
    struct Info {
        let title: String
        let artist: String?
    }

    /// 读失败(无 AX 权限/app 无此结构)返回 nil
    static func read(pid: pid_t) -> Info? {
        let app = AXUIElementCreateApplication(pid)
        // app 无响应时 AX 调用默认会阻塞 6s，掐到 1s 免得拖住轮询队列
        AXUIElementSetMessagingTimeout(app, 1.0)
        // 找到播放控制栏就从它开始找，找不到再退回整棵树
        let root = findElement(app, desc: "播放控制栏", depth: 0) ?? app
        return findInfo(in: root, depth: 0)
    }

    private static func findInfo(in element: AXUIElement, depth: Int) -> Info? {
        guard depth <= 6 else { return nil }
        if let desc = description(of: element), let info = parse(desc) { return info }
        guard let children = children(of: element) else { return nil }
        for child in children {
            if let hit = findInfo(in: child, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func findElement(_ element: AXUIElement, desc target: String, depth: Int) -> AXUIElement? {
        guard depth <= 20 else { return nil }
        if description(of: element) == target { return element }
        guard let children = children(of: element) else { return nil }
        for child in children {
            if let hit = findElement(child, desc: target, depth: depth + 1) { return hit }
        }
        return nil
    }

    /// `歌曲名：虚拟 - 歌手名：陈粒` → title=虚拟, artist=陈粒
    private static func parse(_ desc: String) -> Info? {
        guard let head = desc.range(of: "歌曲名：") else { return nil }
        let rest = String(desc[head.upperBound...])
        if let sep = rest.range(of: " - 歌手名：") {
            let title = String(rest[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            let artist = String(rest[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            return Info(title: title, artist: artist.isEmpty ? nil : artist)
        }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : Info(title: title, artist: nil)
    }

    private static func description(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return nil }
        return list
    }
}
