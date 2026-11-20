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

    static func post(_ key: Int32) {
        for down in [true, false] {
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
            ), let cgEvent = event.cgEvent else { continue }
            cgEvent.post(tap: .cghidEventTap)
        }
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
