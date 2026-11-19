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
    /// 播放器宿主 app 的 pid（「打开」按钮用它调度窗口）。nil = app 已不在运行——
    /// 这种条目不进卡片：有音源就说明 app 开着，卡片上的一切动作都以它为前提
    let pid: pid_t?
    let isPlaying: Bool
    let elapsed: Double?
    let duration: Double?
    /// 这条信息能走哪条控制通道
    let control: ControlChannel

    func setting(isPlaying: Bool) -> NowPlayingInfo {
        NowPlayingInfo(title: title, artist: artist, album: album, appBundleID: appBundleID,
                       appName: appName, pid: pid, isPlaying: isPlaying, elapsed: elapsed,
                       duration: duration, control: control)
    }

    func setting(pid: pid_t?) -> NowPlayingInfo {
        NowPlayingInfo(title: title, artist: artist, album: album, appBundleID: appBundleID,
                       appName: appName, pid: pid, isPlaying: isPlaying, elapsed: elapsed,
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
/// **展示对象是粘性的**：只有「有 app 新开播」或它退出才换人，暂停不换（`updateCurrent`）。
/// 媒体键无法定向（DEV-081），卡片一旦切到别的 app 上按钮就控不到它了。
/// 播放态由 `deriveIsPlaying` 一处判定，点击后先翻转图标再验证（`beginPendingToggle`）。
///
/// **只认白名单**（`allowedBundles`）：两个来源都在入口过滤，别的 app 在出声/上报都不出卡。
/// 过滤点必须三处齐全——出声哨兵、`actives`、`media`——漏一处就会有路径把非白名单 app 顶上来。
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
    /// 「正在播放」卡片只展示/控制这些 app。用 `sameApp` 前缀比对，
    /// 这样 Chrome 的 audio helper（com.google.Chrome.helper）、
    /// QQ音乐被归并的 WebKit 媒体进程（归并后是宿主 bundle）都能命中。
    private static let allowedBundles = [
        "com.google.Chrome",
        "com.tencent.QQMusicMac",
        "com.apple.Music",
    ]

    /// bundleID 是否在白名单里（nil = 无归属，一律拒绝）
    static func isAllowed(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return allowedBundles.contains { AudioActivityMonitor.sameApp(bundleID, $0) }
    }

    /// bundleID 对应的**宿主 app**（卡片上「打开」按钮要激活的那个进程）。nil = 没在运行。
    ///
    /// 只认 `.regular` 进程并精确匹配优先：Chrome 的 helper 也是 `NSRunningApplication`，
    /// 拿它的 pid 去激活窗口只会落空（而且 `sameApp` 前缀比对会把 helper 判成宿主）。
    static func runningApp(bundleID: String?) -> NSRunningApplication? {
        guard let bundleID else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular
        }
        if let exact = apps.first(where: { $0.bundleIdentifier == bundleID }) { return exact }
        // 会话报的是 helper / WebKit 进程的 bundle 时，前缀归并到宿主
        return apps.first { AudioActivityMonitor.sameApp($0.bundleIdentifier, bundleID) }
    }

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
    /// 每个 app 最近一次「被操作」的时刻：进了出声列表（开始播），或上报会话的播放态翻转
    /// （暂停→播放不改变出声列表，只能从 playbackRate 看出来）。卡片展示它最大的那个，
    /// 也就是用户最后操作音频的那个 app（见 DEV-078）。
    /// 只在轮询队列里读写。
    private var operatedAt: [String: CFAbsoluteTime] = [:]
    /// 上一次的出声列表 / 上报会话播放态，用来判「刚变化」
    private var previousActives: Set<String> = []
    private var lastMediaPlaying: [String: Bool] = [:]
    /// 每个 app 上一次看到的上报内容（曲名 + 进度）。浏览器这种「暂停后槽和输出流都还占着」的
    /// app，换一个视频时出声列表、owner、playbackRate 全都不变，只有曲名/进度会跳（见 DEV-078）
    private var lastMediaIdentity: [String: (title: String?, elapsed: Double?)] = [:]
    /// 混音刚静过。暂停后 app 常常仍占着输出流（出声列表不变、也不上报），
    /// 只能靠「静→响」这一跳认出「刚有人点了播放」（见 DEV-078）。由主线程置位、队列消费
    private var sawSilence = false
    private var inFlight = false
    private var staleCount = 0
    /// 「混音有声但出声列表为空」的连续补查次数。进程注册只会比声音晚一拍，
    /// 连补 `emptyRetryLimit` 次还是空，说明响的是白名单外的 app——再补就是每轮白跑一次
    /// osascript 子进程（Safari 放视频时实测会一直触发）
    private var emptyRetries = 0
    private static let emptyRetryLimit = 3
    /// 「当前播放器」：**粘性**状态，只有「有 app 新开播」或它退出才换人，暂停不换。
    /// 暂停就换人会让卡片落到「媒体键控不到的 app」上——点暂停反而把上一个播放器拉起来，
    /// 最后两个都在播（见 DEV-084）。只在轮询队列里读写。
    private struct CurrentPlayer {
        var pid: pid_t
        var bundleID: String?
        var name: String?
        /// 被认定为当前播放器的时刻；只有 `operatedAt` 比它更晚的候选才能顶掉它
        var at: CFAbsoluteTime
    }
    private var current: CurrentPlayer?
    /// 点击播放/暂停后的待确认意图：图标先翻转，再用「律动 + 出声列表」验证（见 DEV-085）。
    /// 只在主线程读写。
    private struct PendingToggle {
        let bundleID: String
        let isPlaying: Bool
        let deadline: CFAbsoluteTime
    }
    private var pendingToggle: PendingToggle?
    /// 不上报 Now Playing 的 app 的播放态锁存（主线程，见 `audioOnlyLatch`）
    private var audioOnlyPlaying: Bool?
    private var audioOnlyKey: String?
    /// 待确认窗口时长：够 0.3s 哨兵和 ≈0.1s 的电平把真实状态报上来
    private static let toggleWindow: TimeInterval = 1.6
    /// 「按 app 抓音频」的探针当前对准哪个 pid（队列侧，避免每次轮询都往主线程塞 setTarget）
    private var probeTargetPID: pid_t?
    /// 面板开着才探测；关掉时不留一条空转的捕获流
    private var probeEnabled = false
    /// 上一次的日志摘要,只在内容变化时打,避免 2s 一条刷屏
    private var lastDebugSummary: String?
    /// 上一次的出声列表摘要（同上，只在变化时打）
    private var lastActivesSummary: String?
    /// 上一次被白名单挡掉的摘要（同上）
    private var lastBlockedSummary: String?
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
        // 按 app 抓到的电平：这才是「卡片上这个 app 停了没有」的唯一准信
        // （系统混音是所有 app 的叠加，`IsRunningOutput` 暂停后不归零，见 DEV-086）
        AppAudioProbe.shared.$isSounding
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.applySounding(value) }
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
            // 面板刚打开：播放态锁存作废，按这一轮的真实信号重判。
            // **不重挑展示对象**——面板是悬停 HUD，频繁开关；每次重开都按「谁在响」重挑
            // 会让「暂停当前播放器、切个窗口」就跳卡（见 DEV-087）。
            // 关着期间真的有人开播，靠 `previousActives` 还是旧集合这一条就能认出来（信号 1）
            audioOnlyPlaying = nil
            audioOnlyKey = nil
            queue.async { [weak self] in
                self?.probeEnabled = true
                // 补查计数只在轮询队列里读写，重置也放这里
                self?.emptyRetries = 0
            }
            tick()
        } else {
            timer?.invalidate()
            timer = nil
            activityTimer?.invalidate()
            activityTimer = nil
            lastActiveSet = []
            // 刻意不清 `operatedAt`/`previousActives`/`current`：面板关着的时候用户也可能换着播，
            // 留着「上一次是谁」比每次重开都退回 owner 更贴近用户预期
            pendingToggle = nil
            // 收起就停掉按 app 的音频探测，别留一条空转的捕获流
            queue.async { [weak self] in
                self?.probeEnabled = false
                self?.probeTargetPID = nil
            }
            AppAudioProbe.shared.setTarget(pid: nil, bundleID: nil)
            nowPlaying = nil
            staleCount = 0
            lastDebugSummary = nil
            lastBlockedSummary = nil
        }
    }

    /// 出声列表的高频哨兵：枚举 CoreAudio process object 只是几个属性读取（微秒级），
    /// 但元数据（子进程 + AX + CGWindowList）很贵。分开跑——谁开始/停止出声 0.3s 内就能发现，
    /// 不用等 2s 元数据轮询，体感才是「切 app 立刻反应」。
    /// 只比出声集合：会话快照在进程内是冻结的（DEV-082），比它没有意义
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
        // 先过白名单：非白名单 app 的进出不该触发补查，也不该参与播放态锁存
        let bundles = AudioActivityMonitor.activeApps()
            .filter { Self.isAllowed($0.bundleID) }
            .map { $0.bundleID ?? "?" }
        let set = Set(bundles)
        guard set != lastActiveSet else { return }
        let entered = set.subtracting(lastActiveSet)
        let left = lastActiveSet.subtracting(set)
        // 面板刚打开时 `lastActiveSet` 是空的，整张表都会被算成「刚进入」——没有前一帧，不算证据
        let hadPrevious = !lastActiveSet.isEmpty
        lastActiveSet = set
        // 进/出出声列表是「不上报的 app」最可靠的两个正向证据：离开 = 停了，重新进入 = 又开始播。
        // 光看「在不在列表里」判在播是错的（暂停后不一定归零，见 DEV-075/086）
        if hadPrevious, let bid = nowPlaying?.appBundleID {
            if left.contains(where: { AudioActivityMonitor.sameApp($0, bid) }) { setAudioOnlyLatch(bid, false) }
            if entered.contains(where: { AudioActivityMonitor.sameApp($0, bid) }) { setAudioOnlyLatch(bid, true) }
        }
        if Self.debug {
            ZSLog("NowPlaying: 哨兵 set=[\(bundles.joined(separator: ","))] → 立刻补查")
        }
        tick()
    }

    /// 写锁存；探针能判时以探针为准，别让列表信号覆盖真实电平
    private func setAudioOnlyLatch(_ bid: String, _ value: Bool) {
        guard AppAudioProbe.shared.sounding(for: bid) == nil else { return }
        audioOnlyKey = bid
        audioOnlyPlaying = value
        guard let info = nowPlaying, AudioActivityMonitor.sameApp(info.appBundleID, bid),
              info.isPlaying != value else { return }
        // 待确认窗口内：和点击意图相反的先不动图标，等窗口结束（超时）再认真实信号，
        // 否则「点了暂停又立刻弹回来」——点失败时也只是晚 1.6s 纠正
        if let p = pendingToggle, AudioActivityMonitor.sameApp(p.bundleID, bid), p.isPlaying != value { return }
        if Self.debug { ZSLog("NowPlaying: 锁存 \(value ? "在播" : "暂停") → \(bid)") }
        nowPlaying = info.setting(isPlaying: value)
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
        // 由静变响（removeDuplicates 保证这是变化）：只有一个候选时必然就是它——这是
        // 「暂停后仍占着输出流、也不上报」的 app 唯一能被认出来的正向证据
        if audible, let info = nowPlaying, AppAudioProbe.shared.sounding(for: info.appBundleID) == nil,
           lastActiveSet.count == 1,
           lastActiveSet.contains(where: { AudioActivityMonitor.sameApp($0, info.appBundleID) }) {
            audioOnlyKey = info.appBundleID
            audioOnlyPlaying = true
        }
        if let info = nowPlaying {
            let derived = deriveIsPlaying(info, audible: audible)
            if let p = pendingToggle, AudioActivityMonitor.sameApp(p.bundleID, info.appBundleID) {
                // 待确认期间只认点击意图；电平一旦与意图一致就提前收窗，把控制权交回真实状态
                if derived == p.isPlaying {
                    pendingToggle = nil
                } else if info.isPlaying != p.isPlaying {
                    nowPlaying = info.setting(isPlaying: p.isPlaying)
                }
            } else if info.isPlaying != derived {
                nowPlaying = info.setting(isPlaying: derived)
            }
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

    /// 播放态的**唯一**判定入口（主线程）。
    ///
    /// 优先级：① 按 app 抓到的电平（`AppAudioProbe`）——它直接回答「卡片上这个 app 现在有没有出声」，
    /// 不受别的声源干扰，也不受 `IsRunningOutput` 暂停不归零的影响（DEV-086）；
    /// ② 上报型 app 的 `playbackRate`——那是它自己的状态；
    /// ③ 不上报的 app 用**锁存**（`audioOnlyLatch`），只认正向证据，不再用「混音有声 + 在出声列表里」
    /// 每次重推（暂停后仍占着输出流的 app 会一直被算成在播）。
    private func deriveIsPlaying(_ info: NowPlayingInfo, audible: Bool?) -> Bool {
        if let sounding = AppAudioProbe.shared.sounding(for: info.appBundleID) { return sounding }
        if info.control == .mediaRemote { return info.isPlaying }
        // 没在捕获 = 不知道；出声列表还没认出来 = 没有归属依据。都别瞎判
        guard let audible, !lastActiveSet.isEmpty else { return info.isPlaying }
        let inActives = info.appBundleID.map { bid in
            lastActiveSet.contains { AudioActivityMonitor.sameApp($0, bid) }
        } ?? false
        return audioOnlyLatch(info, audible: audible, inActives: inActives)
    }

    /// 不上报 Now Playing 的 app 的播放态锁存。
    ///
    /// 为什么不能每次重推：`IsRunningOutput` 在暂停后不保证归零，别的声源还在响时
    /// 「混音有声」也永远为真——两条叠起来就是「点了暂停，图标和律动还是没停」（DEV-086）。
    /// 这里只认**正向证据**：混音彻底静下来、离开出声列表、静→响、点击意图、探针电平。
    private func audioOnlyLatch(_ info: NowPlayingInfo, audible: Bool, inActives: Bool) -> Bool {
        if audioOnlyKey != info.appBundleID {
            audioOnlyKey = info.appBundleID
            audioOnlyPlaying = nil
        }
        if !audible {
            audioOnlyPlaying = false
            return false
        }
        if let latched = audioOnlyPlaying { return latched }
        // 刚换人、还没任何证据：先按出声列表给个初值
        audioOnlyPlaying = inActives
        return inActives
    }

    /// 探针电平变化：直接改卡片状态，不等 2s 轮询（暂停 0.3s 内图标和律动就一起停）
    private func applySounding(_ value: Bool?) {
        guard timer != nil, let value, let info = nowPlaying,
              AppAudioProbe.shared.sounding(for: info.appBundleID) == value else { return }
        audioOnlyKey = info.appBundleID
        audioOnlyPlaying = value
        if let p = pendingToggle, AudioActivityMonitor.sameApp(p.bundleID, info.appBundleID) {
            // 待确认期间只认点击意图；电平一旦与意图一致就提前收窗
            if value == p.isPlaying {
                pendingToggle = nil
            } else if info.isPlaying != p.isPlaying {
                nowPlaying = info.setting(isPlaying: p.isPlaying)
            }
            return
        }
        if info.isPlaying != value {
            if Self.debug { ZSLog("NowPlaying: 探针 \(value ? "有声" : "静音") → \(info.appBundleID ?? "-")") }
            nowPlaying = info.setting(isPlaying: value)
        }
    }

    /// 把一次读取结果落到 UI
    private func publish(_ info: NowPlayingInfo?) {
        if let read = info {
            // 读取在后台队列跑，可能比电平/出声列表晚一拍，落地时按当前真相再校一次
            var out = read.setting(isPlaying: deriveIsPlaying(read, audible: currentAudible))
            // 点击后的待确认窗口：图标先跟手，真实值到了再收窗（见 DEV-085）
            if let p = pendingToggle, AudioActivityMonitor.sameApp(p.bundleID, out.appBundleID) {
                if out.isPlaying == p.isPlaying {
                    pendingToggle = nil
                } else {
                    out = out.setting(isPlaying: p.isPlaying)
                }
            }
            nowPlaying = out
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

    /// 合并顺序（越靠前越优先）：
    /// 1. **粘性当前播放器**（`updateCurrent`，DEV-084）：只要它还在跑就由它出卡，
    ///    哪怕已经暂停——暂停就换人会让卡片落到「媒体键控不到的 app」上；
    /// 2. 它同时有上报会话时用会话信息（曲名/进度更全）；
    /// 3. 都没有才退到暂停态的会话。
    /// - Parameter audible: 系统混音当前有没有声音；nil = 没在捕获，属于「不知道」，
    ///   此时不能判暂停。出声列表非空但没声音 = app 只是占着输出流（QQ音乐暂停后
    ///   `IsRunningOutput` 不归零），要按「已暂停」展示
    private func read(audible: Bool?) -> NowPlayingInfo? {
        // 会话必须走子进程读：进程内的 `MRNowPlayingRequest` 属性**冻结在首次读取**
        // （实测 app 退出 12s 后长跑进程还报它的 bundleID，新进程立刻正确），
        // 而 C 接口在这版 macOS 上被阉（PID 恒 0、DisplayID 恒 nil），见 DEV-082
        let rawMedia = readNowPlaying()
        // 白名单 + 存活校验：非白名单 app 的上报会话直接丢弃。不丢的话 `current` 为空时
        // 会退到「暂停态会话」那条分支直接出卡（Safari/语音备忘录都会走到这里）。
        // 存活校验同时兜住「app 已退出、会话还残留」的条目——卡片上的「打开」按钮
        // 和媒体控制都以 app 在跑为前提，pid 拿不到就不出卡
        let media = rawMedia.flatMap { info -> NowPlayingInfo? in
            guard Self.isAllowed(info.appBundleID),
                  let app = Self.runningApp(bundleID: info.appBundleID) else { return nil }
            return info.setting(pid: app.processIdentifier)
        }
        // owner 就用会话自己报的 bundleID——它和媒体键的目标是同一个，而且比单独再查一次省事
        let owner = media?.appBundleID ?? Self.nowPlayingOwnerBundleID()
        let rawActives = AudioActivityMonitor.activeApps(owner: owner)
        let actives = rawActives.filter { Self.isAllowed($0.bundleID) }
        logBlocked(rawMedia, media: media, rawActives: rawActives, actives: actives)
        logActives(actives, owner: owner, audible: audible)
        trackOperations(actives: actives, media: media, owner: owner, audible: audible)
        updateCurrent(actives, media: media, owner: owner)
        syncProbeTarget()

        // 有声但还没认出是谁在出声（进程注册比声音晚一拍）：马上补查一次，
        // 不然要等下一个 2s 轮询，体感就是「浏览器切回 QQ音乐很慢」。
        // 但连补 `emptyRetryLimit` 次还是空就不再补——白名单外的 app 在响时
        // 出声列表永远是空的，不设上限就是每秒一次子进程（Safari 放视频实测）
        if audible == true, actives.isEmpty {
            if emptyRetries < Self.emptyRetryLimit, let retry = quickRetry() {
                emptyRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + retry) { [weak self] in self?.tick() }
            }
        } else {
            emptyRetries = 0
        }

        if let cur = current {
            if let media, AudioActivityMonitor.sameApp(media.appBundleID, cur.bundleID) {
                logIfChanged("media app=\(media.appBundleID ?? "-")（当前播放器）")
                return media
            }
            if let info = audioOnlyInfo(cur, actives: actives, audible: audible) {
                return info
            }
        }

        if let media {
            logIfChanged("media(paused) app=\(media.appBundleID ?? "-")")
            return media
        }
        logIfChanged("idle owner=\(owner ?? "-")")
        return nil
    }

    /// 维护「当前播放器」。**只有比它更晚的「开播信号」才能顶掉它**：
    /// 暂停、退出出声列表都不换人——媒体键只会落到最后开播的那个 app 上，
    /// 卡片一旦跟着声音跑到别人身上，按钮就控不到卡片上的人了（DEV-081/084）。
    private func updateCurrent(_ actives: [AudioActivity], media: NowPlayingInfo?, owner: String?) {
        let now = CFAbsoluteTimeGetCurrent()
        // 当前播放器退出了，或者不在白名单（改白名单前认下的残留）：让位
        if let cur = current, livePID(for: cur) == nil || !Self.isAllowed(cur.bundleID) {
            current = nil
        }

        // 出声列表里「最后被操作」的那个（时间戳相同按数组顺序，owner/媒体类在前，别用不稳定排序）
        let ranked = actives.enumerated().sorted { lhs, rhs in
            let l = operatedAt[lhs.element.bundleID ?? ""] ?? 0
            let r = operatedAt[rhs.element.bundleID ?? ""] ?? 0
            return l == r ? lhs.offset < rhs.offset : l > r
        }.map(\.element)
        let best = ranked.first
        let bestAt = best.flatMap { operatedAt[$0.bundleID ?? ""] } ?? 0

        if let cur = current {
            if let best, bestAt > cur.at {
                current = CurrentPlayer(pid: best.pid, bundleID: best.bundleID, name: best.name, at: bestAt)
                if Self.debug { ZSLog("NowPlaying: current \(cur.bundleID ?? "-") → \(best.bundleID ?? "-")（新开播）") }
            } else if let best, AudioActivityMonitor.sameApp(best.bundleID, cur.bundleID) {
                // 它自己又被操作了：刷新时间戳和身份，别被更旧的记录顶掉
                current = CurrentPlayer(pid: best.pid, bundleID: best.bundleID, name: best.name,
                                        at: max(cur.at, bestAt))
            }
            logCurrent(actives)
            return
        }

        // 还没有当前播放器：最后被操作的出声方 → owner → 正在播的上报会话
        if let best {
            current = CurrentPlayer(pid: best.pid, bundleID: best.bundleID, name: best.name,
                                    at: bestAt > 0 ? bestAt : now)
        } else if let owner, let owned = actives.first(where: { AudioActivityMonitor.sameApp($0.bundleID, owner) }) {
            current = CurrentPlayer(pid: owned.pid, bundleID: owned.bundleID, name: owned.name, at: now)
        } else if let media, let pid = media.pid, media.isPlaying {
            current = CurrentPlayer(pid: pid, bundleID: media.appBundleID,
                                    name: media.appName, at: now)
        }
        if Self.debug, let cur = current {
            ZSLog("NowPlaying: current=\(cur.bundleID ?? "?")（初始）")
        }
        logCurrent(actives)
    }

    /// 排查「为什么显示的是它」：每个候选距今多久被记成「刚被操作」
    private func logCurrent(_ actives: [AudioActivity]) {
        guard Self.debug, let cur = current else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let ages = actives.map { a -> String in
            let bid = a.bundleID ?? "?"
            let age = operatedAt[bid].map { String(format: "%.1fs", now - $0) } ?? "从未"
            return "\(bid)=\(age)"
        }.joined(separator: " ")
        ZSLog("NowPlaying: current=\(cur.bundleID ?? "?") [\(ages)]")
    }

    /// 让「按 app 抓音频」的探针对准当前播放器。只在换人时重建捕获流（队列侧判重，别每轮都塞主线程）
    private func syncProbeTarget() {
        let want = probeEnabled ? current.flatMap { livePID(for: $0) } : nil
        guard want != probeTargetPID else { return }
        probeTargetPID = want
        let bid = current?.bundleID
        DispatchQueue.main.async {
            AppAudioProbe.shared.setTarget(pid: want, bundleID: bid)
        }
    }

    /// 当前播放器还活着的 pid。app 重启过（pid 变了）就按 bundleID 重新认一次
    private func livePID(for cur: CurrentPlayer) -> pid_t? {
        if let app = NSRunningApplication(processIdentifier: cur.pid), !app.isTerminated {
            return cur.pid
        }
        guard let bid = cur.bundleID,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  !$0.isTerminated && AudioActivityMonitor.sameApp($0.bundleIdentifier, bid)
              }) else { return nil }
        return app.processIdentifier
    }

    /// CoreAudio 兜底来源：曲名读 AX 播放控制栏，读不到退回窗口标题
    private func audioOnlyInfo(_ cur: CurrentPlayer,
                               actives: [AudioActivity],
                               audible: Bool?) -> NowPlayingInfo? {
        guard let pid = livePID(for: cur) else {
            current = nil
            return nil
        }
        let axInfo = AXMediaInfoReader.read(pid: pid)
        let title = axInfo?.title ?? WindowTitleReader.title(forPID: pid, appName: cur.name)
        // 卡片上是谁，点下去就控谁（媒体键路由给最后开播的那个 app，正是卡片上的这个），
        // 所以按钮不用置灰
        logIfChanged("audio-only app=\(cur.bundleID ?? "-") title=\(title ?? "nil") n=\(actives.count) audible=\(audible.map { "\($0)" } ?? "-")")
        return NowPlayingInfo(
            title: title,
            artist: axInfo?.artist,
            album: nil,
            appBundleID: cur.bundleID,
            appName: cur.name,
            pid: pid,
            // 它在出声列表里不代表在响：暂停后仍可能占着输出流，以「有没有声音」为准
            isPlaying: audible ?? true,
            elapsed: nil,
            duration: nil,
            control: .mediaKey
        )
    }

    /// 读「系统 Now Playing」。子进程优先（唯一能拿到新鲜值的路径，~77ms，跑在轮询队列上），
    /// 失败再退回进程内——进程内的值虽然会冻结，但比什么都没有强
    private func readNowPlaying() -> NowPlayingInfo? {
        if let fresh = readViaSubprocess() { return fresh }
        return useSubprocess ? nil : readInProcess()
    }

    /// 记录「谁刚被操作」。四个信号，缺一个就会有一个方向切不过去：
    /// 1. 新进出声列表 —— 开始播（暂停后进程消失的 app 走这条，QQ音乐就是）；
    /// 2. 上报会话 playbackRate 由停转播 —— 暂停后仍占着槽的 app（浏览器）走这条；
    /// 3. 混音由静变响且只有一个候选 —— 暂停后仍占着输出流的 app 走这条（它既不在 1 也不在 2）；
    /// 4. 上报内容换了一条且正在播（曲名变）—— 槽和输出流都没动静时，只有这里看得出来
    ///
    /// **刻意不认「会话 owner 换人」**：owner 只表示谁占着会话槽，切窗口、把浏览器点到前台
    /// 都会让它换人（会话重新注册），但那不是「谁开始播了」。按它记账就会出现
    /// 「只是切了个窗口，卡片就从 QQ音乐跳到浏览器，而按钮还在控 QQ」（见 DEV-087）。
    /// 浏览器真的开始播时，出声列表（信号 1）或 playbackRate（信号 2）一定会动，不需要它。
    private func trackOperations(actives: [AudioActivity], media: NowPlayingInfo?,
                                 owner: String?, audible: Bool?) {
        let now = CFAbsoluteTimeGetCurrent()
        let live = Set(actives.compactMap { $0.bundleID })

        // 1) 新进出声列表
        for bid in live where !previousActives.contains(bid) { operatedAt[bid] = now }
        previousActives = live

        // 2) 上报会话由停转播（同一个 app 自己暂停再播，owner 不变）
        if let media, let bid = media.appBundleID {
            if lastMediaPlaying[bid] == false, media.isPlaying { operatedAt[bid] = now }
            lastMediaPlaying[bid] = media.isPlaying

            // 4) 会话换了一条且正在播：换了首歌或新开了个视频。
            // 只认「曲名变了」——进度跳回 0 在会话重新注册时也会出现（切窗口就够触发），
            // 而暂停中的会话改标题也不是「开始播」
            if media.isPlaying, let prev = lastMediaIdentity[bid],
               let t = media.title, let pt = prev.title, t != pt {
                operatedAt[bid] = now
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

    /// 白名单挡掉了谁：只在变化时打。排查「明明在放歌但卡片是空的」时，先看这条
    private func logBlocked(_ rawMedia: NowPlayingInfo?, media: NowPlayingInfo?,
                            rawActives: [AudioActivity], actives: [AudioActivity]) {
        guard Self.debug else { return }
        let mediaSummary: String
        if let rawMedia, media == nil {
            mediaSummary = rawMedia.appBundleID ?? "?"
        } else {
            mediaSummary = "-"
        }
        let activesSummary = rawActives
            .filter { !Self.isAllowed($0.bundleID) }
            .map { $0.bundleID ?? "?" }
            .joined(separator: ",")
        let summary = "media=\(mediaSummary) actives=[\(activesSummary)]"
        guard summary != lastBlockedSummary else { return }
        lastBlockedSummary = summary
        ZSLog("NowPlaying: 白名单过滤 \(summary)")
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
        // 播放/暂停：先把图标翻过去，再让电平/出声列表验证（DEV-085）。
        // 只翻 togglePlay——上一首/下一首不改变播放态。放在通道判断之后，
        // 发不出去（符号没找到 / .none）就别翻，免得图标闪一下又退回去
        switch info.control {
        case .mediaRemote:
            guard let fn = sendCommandFn else { return }
            if command == .togglePlay { beginPendingToggle(for: info) }
            fn(UInt32(command.rawValue), nil)
        case .mediaKey:
            if command == .togglePlay { beginPendingToggle(for: info) }
            MediaKey.post(Self.mediaKey(for: command))
        case .none:
            return
        }
        if Self.debug { ZSLog("NowPlaying: sent \(command) via \(info.control)") }
        // 发送后补查：0.2s 让媒体键落地，0.6/1.2s 兜住反应慢的 app（inFlight 会挡掉重叠的）
        for delay in [0.2, 0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tick() }
        }
    }

    /// 点击即翻转 + 待确认窗口。
    ///
    /// 为什么不能只信轮询：上报型 app 的 `playbackRate` 要等 2s 轮询才更新（字段缺失时还会
    /// 被当成「在播」），不上报的 app 更是完全靠电平——用户点完按钮的 0.2s 里图标一动不动，
    /// 观感就是「点了没反应/图标不对」。所以先翻转，再在 `toggleWindow` 内用真实信号确认：
    /// 电平或出声列表一旦与意图一致就提前收窗，超时还没对上就认命改回真实值（见 DEV-085）。
    private func beginPendingToggle(for info: NowPlayingInfo) {
        guard let bid = info.appBundleID else { return }
        let target = !info.isPlaying
        nowPlaying = info.setting(isPlaying: target)
        pendingToggle = PendingToggle(bundleID: bid, isPlaying: target,
                                      deadline: CFAbsoluteTimeGetCurrent() + Self.toggleWindow)
        if Self.debug { ZSLog("NowPlaying: 待确认 \(bid) → \(target ? "播放" : "暂停")") }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toggleWindow) { [weak self] in
            guard let self, let p = self.pendingToggle,
                  CFAbsoluteTimeGetCurrent() >= p.deadline else { return }
            self.pendingToggle = nil
            if let info = self.nowPlaying, AudioActivityMonitor.sameApp(p.bundleID, info.appBundleID) {
                let truth = self.deriveIsPlaying(info, audible: self.currentAudible)
                if info.isPlaying != truth { self.nowPlaying = info.setting(isPlaying: truth) }
                if Self.debug { ZSLog("NowPlaying: 待确认超时 → 真实值 \(truth)") }
            }
            self.tick()
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
            // pid 由 `read()` 统一补：那里才做白名单 + 存活校验
            pid: nil,
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
            pid: nil,
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
