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
    /// 出声列表哨兵（0.3s），见 `checkActivity`
    private var activityTimer: Timer?
    private var lastActiveSet: Set<String> = []
    private var lastSession: SessionSnapshot?
    /// 每个 app 最近一次「被操作」的时刻：进了出声列表（开始播），或上报会话的播放态翻转
    /// （暂停→播放不改变出声列表，只能从 playbackRate 看出来）。卡片展示它最大的那个，
    /// 也就是用户最后操作音频的那个 app（见 DEV-078）。
    /// 只在轮询队列里读写。
    private var operatedAt: [String: CFAbsoluteTime] = [:]
    /// 上一次的出声列表 / 上报会话 owner / 上报会话播放态，用来判「刚变化」
    private var previousActives: Set<String> = []
    private var previousOwner: String?
    private var lastMediaPlaying: [String: Bool] = [:]
    /// 每个 app 上一次看到的上报内容（曲名 + 进度）。浏览器这种「暂停后槽和输出流都还占着」的
    /// app，换一个视频时出声列表、owner、playbackRate 全都不变，只有曲名/进度会跳（见 DEV-078）
    private var lastMediaIdentity: [String: (title: String?, elapsed: Double?)] = [:]
    /// 混音刚静过。暂停后 app 常常仍占着输出流（出声列表不变、也不上报），
    /// 只能靠「静→响」这一跳认出「刚有人点了播放」（见 DEV-078）。由主线程置位、队列消费
    private var sawSilence = false
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
            startActivityWatcher()
            tick()
        } else {
            timer?.invalidate()
            timer = nil
            activityTimer?.invalidate()
            activityTimer = nil
            lastActiveSet = []
            lastSession = nil
            // 刻意不清 `operatedAt`/`previousActives`：面板关着的时候用户也可能换着播，
            // 留着「上一次是谁」比每次重开都退回 owner 更贴近用户预期
            nowPlaying = nil
            staleCount = 0
            lastDebugSummary = nil
        }
    }

    /// 出声列表的高频哨兵：枚举 CoreAudio process object 只是几个属性读取（微秒级），
    /// 但元数据（AX + CGWindowList）很贵。分开跑——谁开始/停止出声 0.3s 内就能发现，
    /// 不用等 2s 元数据轮询，体感才是「切 app 立刻反应」
    private func startActivityWatcher() {
        activityTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkActivity()
        }
        RunLoop.main.add(t, forMode: .common)
        activityTimer = t
    }

    private func checkActivity() {
        guard timer != nil, !inFlight else { return }
        let bundles = AudioActivityMonitor.activeApps().map { $0.bundleID ?? "?" }
        let set = Set(bundles)
        let session = Self.sessionSnapshot()
        let changed = set != lastActiveSet || session != lastSession
        lastActiveSet = set
        lastSession = session
        guard changed else { return }
        if Self.debug {
            ZSLog("NowPlaying: 哨兵 set=[\(bundles.joined(separator: ","))] owner=\(session.owner ?? "-") playing=\(session.playing) title=\(session.title ?? "-") → 立刻补查")
        }
        tick()
    }

    /// 上报会话的轻量快照（几次 ObjC 属性读，微秒级）。哨兵拿它判「会话动没动」：
    /// 出声列表可能一动不动，但曲名变了/播放态翻了都说明那边刚被操作过
    struct SessionSnapshot: Equatable {
        var owner: String?
        var playing: Bool
        var title: String?
    }

    static func sessionSnapshot() -> SessionSnapshot {
        // owner 单独取：会话可能没有曲名（浏览器加载了页面但没播），
        // 那时 owner 照样有值，不能因为读不到 item 就把 owner 一起丢了
        var owner: String?
        if let cls = requestClass,
           cls.responds(to: Selector(("localNowPlayingPlayerPath"))),
           let path = cls.value(forKey: "localNowPlayingPlayerPath") as? NSObject,
           path.responds(to: Selector(("client"))),
           let client = path.value(forKey: "client") as? NSObject,
           client.responds(to: Selector(("bundleIdentifier"))) {
            owner = client.value(forKey: "bundleIdentifier") as? String
        }
        guard let cls = requestClass,
              cls.responds(to: Selector(("localNowPlayingItem"))),
              let item = cls.value(forKey: "localNowPlayingItem") as? NSObject,
              item.responds(to: Selector(("nowPlayingInfo"))),
              let info = item.value(forKey: "nowPlayingInfo") as? [String: Any] else {
            return SessionSnapshot(owner: owner, playing: false, title: nil)
        }
        // playbackRate 缺省按「在播」算：老会话不上报这个字段，当成暂停会把图标判反
        let rate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue
        return SessionSnapshot(owner: owner,
                               playing: rate.map { $0 != 0 } ?? true,
                               title: info["kMRMediaRemoteNowPlayingInfoTitle"] as? String)
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
        if audible {
            if CFAbsoluteTimeGetCurrent() - lastTickAt > 0.5 { tick() }
        } else {
            // 记下「静过」：下一次读到的「响」就是刚有人点了播放，得算成一次操作（见 trackOperations）
            queue.async { [weak self] in self?.sawSilence = true }
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
        trackOperations(actives: actives, media: media, owner: owner, audible: audible)
        let active = pickActive(actives, owner: owner)

        // 谁也没在响：锁住「上一次真的在放的那个 app」，别跟着系统会话跳。
        // 只是把浏览器切到前台、或它加载了视频但没播，媒体会话就会挪过去——卡片不该跟着换，
        // 只有真的出声（点了播放）才换（见 DEV-076）
        if audible != true, active == nil, let cached = lastAudioApp,
           let held = idleInfo(from: cached, isPlaying: false) {
            logIfChanged("hold app=\(cached.bundleID ?? "-")")
            return held
        }

        // 有 app 在出声：以「最近开始播的那个」为准（pickActive）。它同时上报了系统会话时
        // 用会话信息（曲名/进度更全），否则走 CoreAudio 兜底
        if let active {
            if let media, AudioActivityMonitor.sameApp(media.appBundleID, active.bundleID) {
                lastAudioApp = (active.pid, active.bundleID, active.name)
                logIfChanged("media app=\(media.appBundleID ?? "-") (最新出声方)")
                return media
            }
            return audioOnlyInfo(active, actives: actives, owner: owner, audible: audible)
        }

        // 出声列表空着：可能是真暂停（QQ音乐这类不上报的 app 暂停后彻底消失），
        // 也可能是出声探测漏了进程（未在 LaunchServices 注册的 helper）。用混音有没有声音区分
        let playing = audible ?? false
        // 有声但还没认出是谁在出声（进程注册比声音晚一拍）：马上补查一次，
        // 不然要等下一个 2s 轮询，体感就是「浏览器切回 QQ音乐很慢」
        if playing, let retry = quickRetry() {
            DispatchQueue.main.asyncAfter(deadline: .now() + retry) { [weak self] in self?.tick() }
        }
        if let cached = lastAudioApp, let info = idleInfo(from: cached, isPlaying: playing) {
            logIfChanged("idle app=\(cached.bundleID ?? "-") playing=\(playing)")
            return info
        }
        // 进程刚起来 / 面板之前没打开过，没有「刚才谁在放」的记忆；
        // 但系统仍认着 now playing owner，按它的 bundleID 找运行中的 app，同样能补出来
        if let bid = owner,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
           let info = idleInfo(from: (app.processIdentifier, bid, app.localizedName), isPlaying: playing) {
            logIfChanged("idle(owner) app=\(bid) playing=\(playing)")
            return info
        }
        logIfChanged("idle owner=\(owner ?? "-")")
        return media
    }

    /// 记录「谁刚被操作」。五个信号，缺一个就会有一个方向切不过去：
    /// 1. 新进出声列表 —— 开始播（暂停后进程消失的 app 走这条，QQ音乐就是）；
    /// 2. 系统会话 owner 换人 —— 浏览器抢槽/开始播都会走这条，不用等出声列表变；
    /// 3. 上报会话 playbackRate 由停转播 —— 暂停后仍占着槽的 app（浏览器）走这条；
    /// 4. 混音由静变响且只有一个候选 —— 暂停后仍占着输出流的 app 走这条（它既不在 1 也不在 3）；
    /// 5. 上报内容换了（曲名变 / 进度跳回 0）—— 槽和输出流都没动静时，只有这里看得出来
    private func trackOperations(actives: [AudioActivity], media: NowPlayingInfo?,
                                 owner: String?, audible: Bool?) {
        let now = CFAbsoluteTimeGetCurrent()
        let live = Set(actives.compactMap { $0.bundleID })

        // 1) 新进出声列表
        for bid in live where !previousActives.contains(bid) { operatedAt[bid] = now }
        previousActives = live

        // 2) 会话 owner 换人：只认「还在出声列表里 + 会话真的在播」的。
        // 光看 owner 会踩两个坑：① 浏览器加载了页面但没播也会抢槽；② 会话没有曲名时
        // `localNowPlayingPlayerPath` 照样指着一个僵尸 app（实测 Chrome 空闲后一直占着）。
        // 这两类都不是「被操作」，认了就会让浏览器永远压着真正在响的 app（见 DEV-080）
        if let owner, owner != previousOwner, let media, media.isPlaying,
           AudioActivityMonitor.sameApp(media.appBundleID, owner),
           live.contains(where: { AudioActivityMonitor.sameApp($0, owner) }) {
            for bid in live where AudioActivityMonitor.sameApp(bid, owner) { operatedAt[bid] = now }
        }
        previousOwner = owner

        // 3) 上报会话由停转播（同一个 app 自己暂停再播，owner 不变）
        if let media, let bid = media.appBundleID {
            if lastMediaPlaying[bid] == false, media.isPlaying { operatedAt[bid] = now }
            lastMediaPlaying[bid] = media.isPlaying

            // 5) 会话内容换了一条（曲名变了 / 进度跳回开头）：换了首歌或新开了个视频，
            // 出声列表和 owner 都可能一动不动，只有这里看得出来
            if let prev = lastMediaIdentity[bid] {
                if let t = media.title, let pt = prev.title, t != pt { operatedAt[bid] = now }
                if let e = media.elapsed, let pe = prev.elapsed, e < pe - 1 { operatedAt[bid] = now }
            }
            lastMediaIdentity[bid] = (media.title, media.elapsed)
        }

        // 4) 静→响且只有一个候选：必然是它。多候选时**不猜**——猜错就是「卡片显示 A、
        // 实际响的是 B」，比不动更糟（见 DEV-079/080）
        if audible == true, sawSilence {
            sawSilence = false
            if actives.count == 1, let bid = actives[0].bundleID { operatedAt[bid] = now }
        }
        operatedAt = operatedAt.filter { live.contains($0.key) }
    }

    /// 卡片展示哪个 app：出声列表里**最后被操作**的那个。
    /// 这样「点了 QQ音乐播放」或「点了浏览器播放」都能立刻切过去，而不是被系统会话槽拖着走（见 DEV-078）
    private func pickActive(_ actives: [AudioActivity], owner: String?) -> AudioActivity? {
        guard !actives.isEmpty else { return nil }
        let best = actives.max {
            (operatedAt[$0.bundleID ?? ""] ?? 0) < (operatedAt[$1.bundleID ?? ""] ?? 0)
        }
        // 一次操作都没记过（刚启动 / 面板刚打开）：跟着系统会话 owner 走，总比随便挑一个强
        if let best, operatedAt[best.bundleID ?? ""] == nil, let owner,
           let owned = actives.first(where: { AudioActivityMonitor.sameApp($0.bundleID, owner) }) {
            return owned
        }
        if Self.debug, let best {
            // 排查「为什么显示的是它」：每个候选距今多久被记成「刚被操作」
            let now = CFAbsoluteTimeGetCurrent()
            let ages = actives.map { a -> String in
                let bid = a.bundleID ?? "?"
                let age = operatedAt[bid].map { String(format: "%.1fs", now - $0) } ?? "从未"
                return "\(bid)=\(age)"
            }.joined(separator: " ")
            ZSLog("NowPlaying: pick=\(best.bundleID ?? "?") [\(ages)] owner=\(owner ?? "-")")
        }
        return best
    }

    /// CoreAudio 兜底来源：曲名读 AX 播放控制栏，读不到退回窗口标题
    private func audioOnlyInfo(_ active: AudioActivity,
                               actives: [AudioActivity],
                               owner: String?,
                               audible: Bool?) -> NowPlayingInfo {
        lastAudioApp = (active.pid, active.bundleID, active.name)
        let axInfo = AXMediaInfoReader.read(pid: active.pid)
        let title = axInfo?.title ?? WindowTitleReader.title(forPID: active.pid, appName: active.name)
        // 展示的就是「最近开始播的那个 app」，媒体键也正好路由给它（实测多个 app 同时出声时
        // 命令落到最后操作的那个），所以按钮不用置灰——卡片上是谁，点下去就控谁
        let isOwner = AudioActivityMonitor.sameApp(owner, active.bundleID)
        logIfChanged("audio-only app=\(active.bundleID ?? "-") title=\(title ?? "nil") owner=\(isOwner) n=\(actives.count) audible=\(audible.map { "\($0)" } ?? "-")")
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
            control: .mediaKey
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
        sessionSnapshot().owner
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
        // 诊断：媒体键只会落到 now playing owner 身上。卡片上是谁、owner 是谁，两者不一致时
        // 按下去就会控到别的 app（浏览器占着槽是最常见的），先把这对值打出来，别靠猜
        if Self.debug {
            let owner = Self.nowPlayingOwnerBundleID()
            let mismatch = !AudioActivityMonitor.sameApp(owner, info.appBundleID)
            ZSLog("NowPlaying: send \(command) card=\(info.appBundleID ?? "-") owner=\(owner ?? "-")\(mismatch ? " ⚠️不一致" : "")")
        }
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
