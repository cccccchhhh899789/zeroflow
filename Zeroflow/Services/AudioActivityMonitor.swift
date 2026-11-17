import AppKit
import CoreAudio
import CoreGraphics

/// 一个正在输出音频的进程（CoreAudio Process Object API，macOS 14+ 公开接口）
struct AudioActivity {
    let pid: pid_t
    let bundleID: String?
    let name: String?
}

/// 「谁在出声」探测器：枚举 CoreAudio 的 process object 列表，筛出正在输出音频的 app 级进程。
///
/// 为什么需要它：系统 Now Playing（MediaRemote）只有 app 主动向 `MPNowPlayingInfoCenter`
/// 上报才有数据。QQ音乐、语音备忘录这类在 macOS 27 上完全不上报——实测播放中
/// `MRMediaRemoteGetNowPlayingClients` 返回空数组、`localNowPlayingItem` 为 nil——
/// 但 CoreAudio 的 `kAudioProcessPropertyIsRunningOutput` 仍能准确反映它们在出声。
enum AudioActivityMonitor {
    /// 当前正在输出音频的 app（已排除守护进程与自身，helper 已归并到宿主 app）
    /// - Parameter owner: 当前 now playing owner 的 bundleID，它排最前面——媒体键只会路由给它，
    ///   也说明系统认它才是播放器；剩下再按「已知音乐类优先」排
    static func activeApps(owner: String? = nil) -> [AudioActivity] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBundle = Bundle.main.bundleIdentifier
        var result: [AudioActivity] = []
        for obj in ids where isRunningOutput(obj) {
            let pid = processPID(obj)
            guard pid > 0, pid != selfPID else { continue }
            guard let entry = resolve(pid: pid) else { continue }
            if let bid = entry.bundleID, bid == selfBundle { continue }
            result.append(entry)
        }
        // 同一个 app 可能既有宿主又有 helper 在出声，按 bundleID 去重
        var seen = Set<String>()
        result = result.filter { entry in
            guard let bid = entry.bundleID else { return true }
            return seen.insert(bid).inserted
        }
        return result.sorted { lhs, rhs in
            let lOwn = sameApp(lhs.bundleID, owner), rOwn = sameApp(rhs.bundleID, owner)
            if lOwn != rOwn { return lOwn }
            let l = mediaRank(lhs.bundleID), r = mediaRank(rhs.bundleID)
            return l == r ? lhs.pid < rhs.pid : l < r
        }
    }

    /// 两个 bundleID 是否属于同一个 app（含 helper / 扩展进程）。
    /// 媒体会话记在宿主 bundle 上（`com.google.Chrome`），音频输出却可能在
    /// `com.google.Chrome.helper`，精确比对会把正在播视频的 Chrome 判成僵尸会话。
    static func sameApp(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs == rhs { return true }
        return lhs.hasPrefix(rhs + ".") || rhs.hasPrefix(lhs + ".")
    }

    /// pid → 归属 app（helper 归并到宿主）。守护进程 / 命令行工具返回 nil
    private static func resolve(pid: pid_t) -> AudioActivity? {
        if let app = NSRunningApplication(processIdentifier: pid) {
            let host = hostApp(for: app)
            // 守护进程（audiomxd / CoreSpeech / assistantd 等）归并不出宿主
            guard host.activationPolicy != .prohibited else { return nil }
            return AudioActivity(pid: host.processIdentifier,
                                 bundleID: host.bundleIdentifier,
                                 name: host.localizedName)
        }
        // Chrome 的音频 helper 没在 LaunchServices 注册成 app，`NSRunningApplication` 直接返回 nil，
        // 整条出声记录会被漏掉（实测症状：明明有声音，出声列表却是空的）。退回可执行路径认 .app
        guard let bid = bundleIdentifier(fromExecutableOf: pid), let host = hostApp(bundleID: bid) else { return nil }
        return AudioActivity(pid: host.processIdentifier,
                             bundleID: host.bundleIdentifier,
                             name: host.localizedName)
    }

    /// 从进程的可执行路径反推所属 .app 的 bundleID（取最内层 .app，helper 再由 hostApp 归并）
    private static func bundleIdentifier(fromExecutableOf pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/", options: .backwards) else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        return Bundle(path: bundlePath)?.bundleIdentifier
    }

    /// bundleID → 宿主 app（取最长前缀的 .regular 进程）
    private static func hostApp(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications
            .filter {
                guard $0.activationPolicy == .regular, let other = $0.bundleIdentifier else { return false }
                return other != bundleID && bundleID.hasPrefix(other + ".")
            }
            // 取最长的前缀（com.google.Chrome.helper → com.google.Chrome，不是 com.google）
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }

    /// helper 进程 → 宿主 app；归并不出来就返回自己
    private static func hostApp(for app: NSRunningApplication) -> NSRunningApplication {
        if let bid = app.bundleIdentifier, let host = hostApp(bundleID: bid) { return host }
        // WebKit 的媒体进程 bundle 是 com.apple.WebKit.GPU,名字却是「<宿主> Graphics and Media」,
        // bundle 前缀归并不出来,只能按名字认宿主(QQ音乐就是 WebKit 播放器)
        return webKitHost(for: app) ?? app
    }

    private static func webKitHost(for app: NSRunningApplication) -> NSRunningApplication? {
        guard let bid = app.bundleIdentifier, bid.hasPrefix("com.apple.WebKit."),
              let name = app.localizedName, !name.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications
            .filter {
                guard $0.activationPolicy == .regular, let host = $0.localizedName, !host.isEmpty, host != name else { return false }
                return name.hasPrefix(host)
            }
            // 名字长的优先：「QQ音乐 Graphics and Media」要认 QQ音乐，别被更短的名字截胡
            .max { ($0.localizedName?.count ?? 0) < ($1.localizedName?.count ?? 0) }
    }

    /// 已知媒体播放器 → 0；其他出声 app（浏览器等）→ 1
    private static func mediaRank(_ bundleID: String?) -> Int {
        guard let bundleID else { return 1 }
        return knownMediaBundles.contains(bundleID) ? 0 : 1
    }

    private static let knownMediaBundles: Set<String> = [
        "com.apple.Music",
        "com.apple.VoiceMemos",
        "com.apple.podcasts",
        "com.apple.TV",
        "com.tencent.QQMusicMac",
        "com.netease.163music",
        "com.spotify.client",
        "com.xiami.mac",
        "com.kugou.mac",
        "com.baidu.music",
    ]

    // MARK: - CoreAudio 属性读取

    private static func isRunningOutput(_ obj: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value == 1
    }

    private static func processPID(_ obj: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
}

/// 读某个进程的普通窗口标题，给「不上报元数据的 app」当曲名兜底。
///
/// 走 CGWindowList（需要屏幕录制权限，Zeroflow 截图功能已有该权限），不碰 AX——
/// 不额外弹辅助功能授权，也不依赖 app 的脚本接口（QQ音乐/语音备忘录都没有）。
enum WindowTitleReader {
    private static var debug: Bool { NowPlayingMonitor.debug }

    /// 该进程最上层的普通窗口标题；无窗口、无权限或标题等于 app 名时返回 nil
    static func title(forPID pid: pid_t, appName: String?) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            if debug { ZSLog("WindowTitleReader: CGWindowList 不可用(缺屏幕录制权限?)") }
            return nil
        }
        var best: (title: String, area: CGFloat)?
        var candidates: [String] = []
        for dict in list {
            let ownerPID = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                ?? (dict[kCGWindowOwnerPID as String] as? pid_t)
            guard ownerPID == pid else { continue }
            // layer 0 = 普通窗口；排除菜单栏/浮层/Dock 之类的窗口
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? (dict[kCGWindowLayer as String] as? Int ?? 0)
            guard layer == 0 else { continue }
            guard let title = (dict[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            candidates.append(title)
            // 标题就是 app 名（"QQ音乐"/"语音备忘录"）说明没有曲目信息，不算有效兜底
            if let appName, title == appName { continue }
            let bounds = dict[kCGWindowBounds as String] as? [String: Any]
            let w = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let h = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            let area = CGFloat(w * h)
            if best == nil || area > best!.area { best = (title, area) }
        }
        if debug {
            // 全表统计:带标题的窗口数为 0 说明没屏幕录制权限(kCGWindowName 需要该权限)
            let namedCount = list.reduce(into: 0) { acc, dict in
                if let t = dict[kCGWindowName as String] as? String, !t.isEmpty { acc += 1 }
            }
            ZSLog("WindowTitleReader: pid=\(pid) 候选=\(candidates) 采用=\(best?.title ?? "nil") 全表=\(list.count) 带标题=\(namedCount) 权限=\(CGPreflightScreenCaptureAccess())")
        }
        return best?.title
    }
}
