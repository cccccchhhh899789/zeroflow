import Foundation
import AppKit
import Combine

/// 「正在播放」模块的一条当前播放信息
struct NowPlayingInfo {
    /// 曲目名。拿不到时为 nil，UI 用 app 名当主标题
    let title: String?
    let artist: String?
    let album: String?
    let appBundleID: String?
    let appName: String?
    let isPlaying: Bool
    let elapsed: Double?
    let duration: Double?
    /// 这条信息能走哪条控制通道
    let control: ControlChannel

    func setting(isPlaying: Bool) -> NowPlayingInfo {
        NowPlayingInfo(title: title, artist: artist, album: album, appBundleID: appBundleID,
                       appName: appName, isPlaying: isPlaying, elapsed: elapsed,
                       duration: duration, control: control)
    }
}

/// 播放控制的三条通道（能力从强到弱）
enum ControlChannel {
    /// app 上报了系统 Now Playing，能收 `MRMediaRemoteSendCommand`
    case mediaRemote
    /// app 不上报，靠系统媒体键控；能点到「当前在播的那个会话」即可
    case mediaKey
    /// 有别的 app 同时在出声、又不是 owner，发了会误控别人，宁可不发
    case none
}

/// 灵动岛「正在播放」：双源合并。
///
/// 1. **系统 Now Playing**（MediaRemote 私有框架）：读取优先进程内 `MRNowPlayingRequest`
///    类属性（macOS 15.4+ 后唯一未封的读取路径，对无自动化授权的进程开放；已实测），
///    类不可用时降级 osascript JXA 子进程。这条源能拿到曲名/歌手/进度，也能发播放控制。
/// 2. **CoreAudio 出声进程**（`AudioActivityMonitor`）：兜住那些压根不向系统上报的 app
///    （QQ音乐、语音备忘录实测均不上报）。只能拿到 app 身份，曲名靠 AX 播放控制栏/窗口标题兜底，
///    控制走系统媒体键。播放态一律以「系统混音有没有声音」为准（`AudioSpectrumMonitor.isAudible`），
///    因为 `IsRunningOutput` 在暂停后不保证归零。
///
/// 合并规则见 `read()`。播放控制走 `MRMediaRemoteSendCommand`（dlsym）。
final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    /// 调试日志开关。环境变量只对直接执行二进制有效；用 `open` 启动时改用
    /// `defaults write com.zeroflow.app notchDebug -bool true`（同 dockPreviewDebug 的做法）
    static let debug = ProcessInfo.processInfo.environment["ZEROFLOW_NOTCH_DEBUG"] == "1"
        || UserDefaults.standard.bool(forKey: "notchDebug")
    /// 轮询间隔(s)
    private static let interval: TimeInterval = 2
    /// 连续多少次读不到内容后才清空展示(避免瞬时失败闪空)
    private static let staleLimit = 3

    enum Command: UInt {
        case togglePlay = 2
        case next = 4
        case previous = 5
    }

    @Published private(set) var nowPlaying: NowPlayingInfo?
    /// 播放控制符号是否找到(MRMediaRemoteSendCommand 可调)
    private(set) var controlsAvailable = false

    private var timer: Timer?
    private var inFlight = false
    private var staleCount = 0
    /// 上一次真的在出声的 app。暂停的瞬间 CoreAudio 立刻报「没人在放」，
    /// 但用户这时最想点的就是「继续播放」——记下来，让它以「已暂停」留在卡片上。
    /// 只在轮询队列里读写，不需要加锁。
    private var lastAudioApp: (pid: pid_t, bundleID: String?, name: String?)?
    /// 上一次的日志摘要,只在内容变化时打,避免 2s 一条刷屏
    private var lastDebugSummary: String?
    /// 上一次的出声列表摘要（同上，只在变化时打）
    private var lastActivesSummary: String?
    /// 上一次真正跑完轮询的时刻，用来给「声音刚开始」触发的补查限流
    private var lastTickAt: CFAbsoluteTime = 0
    /// 上一次「有声但认不出是谁」的补查时刻
    private var lastRetryAt: CFAbsoluteTime = 0
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "zeroflow.notch.nowplaying", qos: .utility)

    /// MRNowPlayingRequest 类;加载失败则降级子进程
    private static let requestClass: AnyObject? = {
        let bundle = Bundle(path: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle, bundle.load() else { return nil }
        return NSClassFromString("MRNowPlayingRequest") as AnyObject?
    }()

    private var useSubprocess: Bool

    /// 实际签名是 `void MRMediaRemoteSendCommand(MRMediaRemoteCommand cmd, CFDictionaryRef options)`。
    /// 早先写成 4 参数并把 options 塞进 MRNowPlayingRequest 类对象,macOS 27 上会抛
    /// `NSInvalidArgumentException: -[NSObject mutableCopyWithZone:]` 崩溃(实测),这里按真实签名修。
    private typealias SendCommandFn = @convention(c) (UInt32, CFDictionary?) -> Void
    private var sendCommandFn: SendCommandFn?

    private init() {
        useSubprocess = Self.requestClass == nil
        if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
           let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommandFn = unsafeBitCast(sym, to: SendCommandFn.self)
        }
        controlsAvailable = sendCommandFn != nil
        if Self.debug {
            ZSLog("NowPlaying: inProcess=\(!useSubprocess) sendCommand=\(controlsAvailable)")
        }
        // 播放态直接由「系统混音有没有声音」驱动：电平一落平就翻成暂停，不用等 2s 轮询
        AudioSpectrumMonitor.shared.$isAudible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] audible in self?.applyAudible(audible) }
            .store(in: &cancellables)
        // 调试开关:不依赖面板切到音乐模块,启动即开始轮询(ZEROFLOW_NOWPLAYING_DEBUG=1)
        if ProcessInfo.processInfo.environment["ZEROFLOW_NOWPLAYING_DEBUG"] == "1"
            || UserDefaults.standard.bool(forKey: "nowPlayingDebug") {
            if Self.debug { ZSLog("NowPlaying: debug 轮询已排期") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if Self.debug { ZSLog("NowPlaying: debug 轮询触发 self=\(self != nil)") }
                self?.setActiveOnMain(true)
            }
        }
    }

    // MARK: - 生命周期

    /// 面板显示时开始轮询、隐藏时停止;任意线程可调
    func setActive(_ active: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.setActiveOnMain(active)
        }
    }

    private func setActiveOnMain(_ active: Bool) {
        if Self.debug { ZSLog("NowPlaying: setActive(\(active)) timer=\(timer != nil)") }
        if active {
            guard timer == nil else { return }
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            tick()
        } else {
            timer?.invalidate()
            timer = nil
            nowPlaying = nil
            staleCount = 0
            lastDebugSummary = nil
        }
    }

    private func tick() {
        guard !inFlight else {
            if Self.debug { ZSLog("NowPlaying: tick 跳过(inFlight)") }
            return
        }
        inFlight = true
        lastTickAt = CFAbsoluteTimeGetCurrent()
        // 主线程采样：isCapturing/isAudible 都是 @Published；没在捕获时是「不知道」，不能当成暂停
        let spectrum = AudioSpectrumMonitor.shared
        let audible = spectrum.isCapturing ? spectrum.isAudible : nil
        queue.async { [weak self] in
            guard let self else { return }
            let info = self.read(audible: audible)
            if Self.debug { ZSLog("NowPlaying: read 完成 info=\(info == nil ? "nil" : "有值")") }
            DispatchQueue.main.async {
                self.inFlight = false
                guard self.timer != nil else { return }
                self.publish(info)
            }
        }
    }

    /// 系统混音由静变响/由响变静：直接改播放态；由静变响还顺带补查一次元数据
    /// （有人刚开始播 = 可能要换 app，别等下一个 2s 轮询才切过去）
    private func applyAudible(_ audible: Bool) {
        guard timer != nil else { return }
        if Self.debug { ZSLog("NowPlaying: audible=\(audible) 当前=\(nowPlaying.map { "\($0.appBundleID ?? "-")/\($0.isPlaying)" } ?? "nil")") }
        if let info = nowPlaying, info.control != .mediaRemote, info.isPlaying != audible {
            nowPlaying = info.setting(isPlaying: audible)
        }
        if audible, CFAbsoluteTimeGetCurrent() - lastTickAt > 0.5 {
            tick()
        }
    }

    /// 混音有没有声音；nil = 没在捕获，属于「不知道」
    private var currentAudible: Bool? {
        let spectrum = AudioSpectrumMonitor.shared
        return spectrum.isCapturing ? spectrum.isAudible : nil
    }

    /// 把一次读取结果落到 UI
    private func publish(_ info: NowPlayingInfo?) {
        var info = info
        // 声音是播放态的唯一真相：轮询结果可能比电平晚（读取在后台队列跑），落地时按当前电平再校一次，
        // 否则会出现「点了播放图标闪一下又变回暂停」——轮询把 applyAudible 的结果盖掉
        if let read = info, read.control != .mediaRemote, let audible = currentAudible {
            info = read.setting(isPlaying: audible)
        }
        if let info {
            nowPlaying = info
            staleCount = 0
        } else if nowPlaying != nil {
            staleCount += 1
            if staleCount >= Self.staleLimit {
                nowPlaying = nil
                staleCount = 0
            }
        }
    }

    // MARK: - 合并两个数据源

    /// 优先系统 Now Playing（信息全、可控制），其缺失或与真实出声方冲突时用 CoreAudio 兜底
    /// - Parameter audible: 系统混音当前有没有声音；nil = 没在捕获，属于「不知道」，
    ///   此时不能判暂停。出声列表非空但没声音 = app 只是占着输出流（QQ音乐暂停后
    ///   `IsRunningOutput` 不归零），要按「已暂停」展示
    private func read(audible: Bool?) -> NowPlayingInfo? {
        let owner = Self.nowPlayingOwnerBundleID()
        let media = useSubprocess ? readViaSubprocess() : readInProcess()
        let actives = AudioActivityMonitor.activeApps(owner: owner)
        logActives(actives, owner: owner, audible: audible)

        // 谁也没在响：锁住「上一次真的在放的那个 app」，别跟着系统会话跳。
        // 只是把浏览器切到前台、或它加载了视频但没播，媒体会话就会挪过去——卡片不该跟着换，
        // 只有真的出声（点了播放）才换（见 DEV-076）
        if audible != true, actives.isEmpty, let cached = lastAudioApp,
           let held = idleInfo(from: cached, isPlaying: false) {
            logIfChanged("hold app=\(cached.bundleID ?? "-")")
            return held
        }

        if let media {
            // 上报的 app 正在出声（helper 进程也算同一家）→ 这是活会话，直接用它
            let mediaIsSounding = media.appBundleID.map { bid in
                actives.contains { AudioActivityMonitor.sameApp($0.bundleID, bid) }
            } ?? false
            // 没有 app 在出声 → media 可能是暂停态，仍用它（暂停也该显示「已暂停」）
            if mediaIsSounding || actives.isEmpty {
                logIfChanged("media app=\(media.appBundleID ?? "-") sounding=\(mediaIsSounding)")
                return media
            }
            // 有别的 app 在出声而 media 的 app 不在 → media 是残留的僵尸会话（实测 Chrome
            // 空闲后仍占着 localNowPlayingPlayerPath），降级展示真正出声的 app
            if Self.debug {
                ZSLog("NowPlaying: media(\(media.appBundleID ?? "-")) 未出声，改用 \(actives.first?.bundleID ?? "-")")
            }
        }

        guard let active = actives.first else {
            // 出声列表空着：可能是真暂停（QQ音乐/语音备忘录这类不上报的 app 暂停后彻底消失），
            // 也可能是出声探测漏了进程（未在 LaunchServices 注册的 helper 会整个看不到）。
            // 用混音有没有声音区分：有声就是「在播」，别硬判暂停
            let playing = audible ?? false
            // 有声但还没认出是谁在出声（进程注册比声音晚一拍）：马上补查一次，
            // 不然要等下一个 2s 轮询，体感就是「浏览器切回 QQ音乐很慢」
            if playing, let retry = quickRetry() {
                DispatchQueue.main.asyncAfter(deadline: .now() + retry) { [weak self] in self?.tick() }
            }
            if let cached = lastAudioApp, let info = idleInfo(from: cached, isPlaying: playing) {
                logIfChanged("idle app=\(cached.bundleID ?? "-") playing=\(playing) control=\(info.control)")
                return info
            }
            // 进程刚起来 / 面板之前没打开过，没有「刚才谁在放」的记忆；
            // 但系统仍认着 now playing owner，按它的 bundleID 找运行中的 app，同样能补出来
            if let bid = owner,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
               let info = idleInfo(from: (app.processIdentifier, bid, app.localizedName), isPlaying: playing) {
                logIfChanged("idle(owner) app=\(bid) playing=\(playing) control=\(info.control)")
                return info
            }
            logIfChanged("idle owner=\(owner ?? "-")")
            return media
        }
        lastAudioApp = (active.pid, active.bundleID, active.name)
        // 曲名优先读 AX 播放控制栏（QQ音乐实测有「歌曲名：X - 歌手名：Y」），
        // 读不到再退回窗口标题；窗口关掉/最小化时窗口标题必然为空
        let axInfo = AXMediaInfoReader.read(pid: active.pid)
        let title = axInfo?.title ?? WindowTitleReader.title(forPID: active.pid, appName: active.name)
        // 媒体键只发给「当前在播的那个会话」。owner 对得上最稳；owner 被别的 app 的残留
        // 会话占着时（浏览器空闲后不释放，实测），只要它是唯一在出声的 app，媒体键照样
        // 会落到它身上（按有声的会话路由），别把按钮置灰成摆设
        let isOwner = AudioActivityMonitor.sameApp(owner, active.bundleID)
        let canControl = isOwner || actives.count <= 1
        logIfChanged("audio-only app=\(active.bundleID ?? "-") title=\(title ?? "nil") owner=\(isOwner) audible=\(audible.map { "\($0)" } ?? "-")")
        return NowPlayingInfo(
            title: title,
            artist: axInfo?.artist,
            album: nil,
            appBundleID: active.bundleID,
            appName: active.name,
            // 它在出声列表里不代表在响：暂停后仍可能占着输出流，以「有没有声音」为准
            isPlaying: audible ?? true,
            elapsed: nil,
            duration: nil,
            control: canControl ? .mediaKey : .none
        )
    }

    /// 出声探测空着时的兜底：app 还在跑就继续把卡片留着（暂停后卡片不能自己变空，用户还要点回去）。
    /// 曲名仍从 AX 读（暂停不影响 AX 树），读不到就退回窗口标题 / app 名。
    /// `isPlaying` 由混音有没有声音决定。
    private func idleInfo(from cached: (pid: pid_t, bundleID: String?, name: String?),
                          isPlaying: Bool) -> NowPlayingInfo? {
        guard let app = NSRunningApplication(processIdentifier: cached.pid), !app.isTerminated else {
            lastAudioApp = nil
            return nil
        }
        let axInfo = AXMediaInfoReader.read(pid: cached.pid)
        let title = axInfo?.title ?? WindowTitleReader.title(forPID: cached.pid, appName: cached.name)
        return NowPlayingInfo(
            title: title,
            artist: axInfo?.artist,
            album: nil,
            appBundleID: cached.bundleID,
            appName: cached.name,
            isPlaying: isPlaying,
            elapsed: nil,
            duration: nil,
            // 卡片上是谁就给谁发：用户要能点回去（媒体键是全局的，指不了具体 app，
            // 但暂停态下没有别的会话在响，通常就落到它身上）
            control: .mediaKey
        )
    }

    /// 出声了但还没认出是谁（进程注册比声音晚一拍）时的补查间隔；nil = 刚查过，别再查
    private func quickRetry() -> TimeInterval? {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRetryAt > 1 else { return nil }
        lastRetryAt = now
        return 0.25
    }

    /// 当前 now playing owner 的 bundleID（媒体键会路由给它）
    static func nowPlayingOwnerBundleID() -> String? {
        guard let cls = requestClass,
              cls.responds(to: Selector(("localNowPlayingPlayerPath"))),
              let path = cls.value(forKey: "localNowPlayingPlayerPath") as? NSObject,
              path.responds(to: Selector(("client"))),
              let client = path.value(forKey: "client") as? NSObject,
              client.responds(to: Selector(("bundleIdentifier"))) else { return nil }
        return client.value(forKey: "bundleIdentifier") as? String
    }

    private func logIfChanged(_ summary: String) {
        guard Self.debug, summary != lastDebugSummary else { return }
        lastDebugSummary = summary
        ZSLog("NowPlaying: \(summary)")
    }

    /// 出声列表只在变化时打一条：排查「明明有声音但列表是空的」时，这条是唯一线索
    private func logActives(_ actives: [AudioActivity], owner: String?, audible: Bool?) {
        guard Self.debug else { return }
        let summary = actives.map { $0.bundleID ?? "?" }.joined(separator: ",")
        guard summary != lastActivesSummary else { return }
        lastActivesSummary = summary
        ZSLog("NowPlaying: actives=[\(summary)] owner=\(owner ?? "-") audible=\(audible.map { "\($0)" } ?? "-")")
    }

    // MARK: - 发送播放控制

    func send(_ command: Command) {
        guard let info = nowPlaying else { return }
        switch info.control {
        case .mediaRemote:
            guard let fn = sendCommandFn else { return }
            fn(UInt32(command.rawValue), nil)
        case .mediaKey:
            MediaKey.post(Self.mediaKey(for: command))
        case .none:
            return
        }
        if Self.debug { ZSLog("NowPlaying: sent \(command) via \(info.control)") }
        // 发送后短暂延迟重查,让 UI 及时反映状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.tick()
        }
    }

    private static func mediaKey(for command: Command) -> Int32 {
        switch command {
        case .togglePlay: return MediaKey.playPause
        case .next: return MediaKey.next
        case .previous: return MediaKey.previous
        }
    }

    // MARK: - 读取:进程内 MRNowPlayingRequest

    private func readInProcess() -> NowPlayingInfo? {
        guard let cls = Self.requestClass else { return nil }
        guard cls.responds(to: Selector(("localNowPlayingItem"))) else { return nil }
        guard let item = cls.value(forKey: "localNowPlayingItem") as? NSObject else { return nil }
        guard item.responds(to: Selector(("nowPlayingInfo"))),
              let info = item.value(forKey: "nowPlayingInfo") as? [String: Any] else { return nil }
        guard let title = string(info, "kMRMediaRemoteNowPlayingInfoTitle") else { return nil }

        var appName: String?
        var appBundleID: String?
        if cls.responds(to: Selector(("localNowPlayingPlayerPath"))),
           let path = cls.value(forKey: "localNowPlayingPlayerPath") as? NSObject,
           path.responds(to: Selector(("client"))),
           let client = path.value(forKey: "client") as? NSObject {
            if client.responds(to: Selector(("displayName"))) {
                appName = client.value(forKey: "displayName") as? String
            }
            if client.responds(to: Selector(("bundleIdentifier"))) {
                appBundleID = client.value(forKey: "bundleIdentifier") as? String
            }
        }
        if appName == nil, let bid = appBundleID {
            appName = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bid }?.localizedName
        }

        let rate = double(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate")
        let isPlaying = rate.map { $0 != 0 } ?? true
        return NowPlayingInfo(
            title: title,
            artist: string(info, "kMRMediaRemoteNowPlayingInfoArtist"),
            album: string(info, "kMRMediaRemoteNowPlayingInfoAlbum"),
            appBundleID: appBundleID,
            appName: appName,
            isPlaying: isPlaying,
            elapsed: double(info, "kMRMediaRemoteNowPlayingInfoElapsedTime"),
            duration: double(info, "kMRMediaRemoteNowPlayingInfoDuration"),
            control: .mediaRemote
        )
    }

    private func string(_ info: [String: Any], _ key: String) -> String? {
        (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func double(_ info: [String: Any], _ key: String) -> Double? {
        (info[key] as? NSNumber)?.doubleValue
    }

    // MARK: - 读取:osascript JXA 子进程(降级路径)

    private func readViaSubprocess() -> NowPlayingInfo? {
        guard let out = Self.runJXA() else { return nil }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\u{241F}", omittingEmptySubsequences: false)
        guard parts.count >= 8, !parts[0].isEmpty, parts[0] != "NOCLASS", parts[0] != "NOITEM" else { return nil }
        let num = { (s: Substring) -> Double? in
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : Double(t)
        }
        return NowPlayingInfo(
            title: String(parts[0]),
            artist: parts[1].isEmpty ? nil : String(parts[1]),
            album: parts[2].isEmpty ? nil : String(parts[2]),
            appBundleID: parts[3].isEmpty ? nil : String(parts[3]),
            appName: parts[4].isEmpty ? nil : String(parts[4]),
            isPlaying: num(parts[7]).map { $0 != 0 } ?? true,
            elapsed: num(parts[6]),
            duration: num(parts[5]),
            control: .mediaRemote
        )
    }

    private static func runJXA() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", jxaScript]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        // 看门狗:4s 未返回则终止,避免卡住轮询队列
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            if p.isRunning { p.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            if debug { ZSLog("NowPlaying: osascript exit=\(p.terminationStatus)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static let jxaScript = """
    ObjC.import('Foundation');
    function run() {
      var b = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
      if (b.isNil()) return '';
      var loaded = b.load;
      var cls = $.NSClassFromString('MRNowPlayingRequest');
      if (cls.isNil()) return 'NOCLASS';
      var item = cls.localNowPlayingItem;
      if (item.isNil()) return 'NOITEM';
      var info = item.nowPlayingInfo;
      if (info.isNil()) return 'NOINFO';
      var t = info.valueForKey('kMRMediaRemoteNowPlayingInfoTitle');
      if (t.isNil() || !t.js.length) return '';
      var app = '', bid = '';
      try {
        var c = cls.localNowPlayingPlayerPath.client;
        app = c.displayName && !c.displayName.isNil() ? c.displayName.js : '';
        bid = c.bundleIdentifier && !c.bundleIdentifier.isNil() ? c.bundleIdentifier.js : '';
      } catch (e) {}
      function s(v) { return (v && !v.isNil() && typeof v.js !== 'undefined') ? String(v.js) : ''; }
      return [t.js, s(info.valueForKey('kMRMediaRemoteNowPlayingInfoArtist')), s(info.valueForKey('kMRMediaRemoteNowPlayingInfoAlbum')), bid, app, s(info.valueForKey('kMRMediaRemoteNowPlayingInfoDuration')), s(info.valueForKey('kMRMediaRemoteNowPlayingInfoElapsedTime')), s(info.valueForKey('kMRMediaRemoteNowPlayingInfoPlaybackRate'))].join('␟');
    }
    """
}
