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
    /// 控不到（既不上报也不是 owner）。展示对象已收敛为 owner（DEV-090），
    /// 正常路径不再产出这个值，保留它是给 UI 的置灰判断和将来「只展示不可控」的场景
    case none
}

/// 灵动岛「正在播放」：以「系统媒体控制的路由目标（owner）」为唯一展示对象。
///
/// **核心不变式：卡片显示谁，播放/暂停就控谁**（DEV-090）。
/// `MRMediaRemoteSendCommand` 和系统媒体键都只会路由给当前 now playing owner，
/// 没有私有授权就无法定向到别的 app（DEV-081）——所以展示对象必须就是 owner。
/// 曾经的「粘性 current」与此相反：卡片可以粘在 owner 之外的 app 上，按下去控到
/// 的是别人（卡片是 QQ音乐、按钮动了 Chrome），已整体废弃。
///
/// 1. **owner 上报了元数据**（MediaRemote 私有框架，子进程读保证新鲜，DEV-082）：
///    有曲名/歌手/进度，控制走 `MRMediaRemoteSendCommand`（dlsym）。
/// 2. **owner 不上报**（QQ音乐这类只注册媒体键路由、不发布元数据的 app）：
///    曲名靠 AX 播放控制栏/窗口标题兜底，控制走系统媒体键（路由目标同样是 owner）。
///    播放态以「按 app 抓音频」的探针为准（`AppAudioProbe`），
///    因为 `IsRunningOutput` 在暂停后不保证归零。
///
/// 切换逻辑（对齐其他 mac 灵动岛）：新音源开播 → 系统把它设为 owner → 卡片跟过去；
/// 音源关闭（app 退出/会话注销）→ owner 换人/落空 → 卡片换成新 owner 或清空；
/// owner 不在白名单或已退出 = 没有可控目标，不出卡。
///
/// **只认白名单**（`allowedBundles`）：owner 和出声列表都在入口过滤，白名单外的 app
/// 占着路由时不出卡——显示了也控不到，违反核心不变式。
///
/// 合并规则见 `read()`。播放态由 `deriveIsPlaying` 一处判定，
/// 点击后先翻转图标再验证（`beginPendingToggle`）。
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
    private var inFlight = false
    private var staleCount = 0
    /// 最近一次读取是不是「确定没有可控音源」（读成功、owner 为空），而不是「读失败」。
    /// 前者可以立即清卡，后者要防抖。轮询队列写、主线程读，单个 Bool 无需加锁
    private var lastReadDefinitiveEmpty = false
    /// 「混音有声但出声列表为空」的连续补查次数。进程注册只会比声音晚一拍，
    /// 连补 `emptyRetryLimit` 次还是空，说明响的是白名单外的 app——再补就是每轮白跑一次
    /// osascript 子进程（Safari 放视频时实测会一直触发）
    private var emptyRetries = 0
    private static let emptyRetryLimit = 3
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
    /// 「按 app 抓音频」的探针当前对准哪几个 app（队列侧，避免每次轮询都往主线程塞 setTargets）
    private var probeTargets: Set<AppAudioProbe.Target> = []
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
        // （系统混音是所有 app 的叠加，`IsRunningOutput` 暂停后不归零，见 DEV-086）。
        // 探针同时探出声列表里的**所有**候选，换人不再靠猜（DEV-089）
        AppAudioProbe.shared.$levels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyLevels() }
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
            // 面板刚打开：播放态锁存作废，按这一轮的真实信号重判
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
            pendingToggle = nil
            // 收起就停掉按 app 的音频探测，别留几条空转的捕获流
            queue.async { [weak self] in
                self?.probeEnabled = false
                self?.probeTargets = []
            }
            AppAudioProbe.shared.setTargets([])
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
        // 由静变响：可能有人刚开播、owner 要换人，别等下一个 2s 轮询才切过去
        if audible, CFAbsoluteTimeGetCurrent() - lastTickAt > 0.5 { tick() }
    }

    /// 混音有没有声音；nil = 没在捕获，属于「不知道」
    private var currentAudible: Bool? {
        let spectrum = AudioSpectrumMonitor.shared
        return spectrum.isCapturing ? spectrum.isAudible : nil
    }

    /// 播放态的**唯一**判定入口（主线程）。
    ///
    /// 优先级：① 按 app 抓到的电平（`AppAudioProbe`）——它直接回答「卡片上这个 app 现在有没有出声」，
    /// 不受别的声源干扰，也不受 `IsRunningOutput` 暂停不归零的影响（DEV-086），
    /// 而且探针覆盖出声列表里的**所有**候选，所以多音源下也是准的（DEV-089）；
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
    /// 这里只认**正向证据**：离开出声列表、混音彻底静下来、静→响、点击意图、探针电平。
    private func audioOnlyLatch(_ info: NowPlayingInfo, audible: Bool, inActives: Bool) -> Bool {
        if audioOnlyKey != info.appBundleID {
            audioOnlyKey = info.appBundleID
            audioOnlyPlaying = nil
        }
        // 离开出声列表 = 肯定没在输出（`IsRunningOutput` 只有假阳性、没有假阴性）。
        // 这条比「混音静没静」可靠得多：多音源时混音永远是响的（DEV-079/089）
        if !inActives {
            audioOnlyPlaying = false
            return false
        }
        if !audible {
            audioOnlyPlaying = false
            return false
        }
        if let latched = audioOnlyPlaying { return latched }
        // 刚换人、还没任何证据：先按出声列表给个初值
        audioOnlyPlaying = true
        return true
    }

    /// 探针电平变化：直接改卡片状态，不等 2s 轮询（暂停 0.3s 内图标和律动就一起停）。
    /// 只有卡片上这个 app 的电平才算数——别的候选在响/静了不该动卡片
    private func applyLevels() {
        guard timer != nil, let info = nowPlaying else { return }
        guard let value = AppAudioProbe.shared.sounding(for: info.appBundleID) else { return }
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
        // 卡片上的 app 刚静了、而别的候选在响：owner 可能要换人，立刻补查一次，
        // 不主动催就要等最多 2s 才挪过去
        if !value, AppAudioProbe.shared.soundingBundleIDs.contains(where: {
            !AudioActivityMonitor.sameApp($0, info.appBundleID)
        }) {
            tick()
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
            // 规则 3：展示对象已退出（音源关闭），或系统确定已没有可控音源 → 立刻清卡，
            // 不吃防抖；其余读空只是子进程抖动，按防抖处理免得卡片闪空
            let displayedAppDead = nowPlaying
                .flatMap { $0.appBundleID }
                .map { Self.runningApp(bundleID: $0) == nil } ?? false
            staleCount += 1
            if displayedAppDead || lastReadDefinitiveEmpty || staleCount >= Self.staleLimit {
                nowPlaying = nil
                staleCount = 0
            }
        }
    }

    // MARK: - 选出展示对象

    /// 展示对象 = **系统媒体控制的路由目标（owner）**，别无候选（DEV-090）。
    ///
    /// 为什么只能是它：`MRMediaRemoteSendCommand` 和系统媒体键都路由给 owner，无法定向
    /// （DEV-081）。卡片若显示 owner 之外的 app，播放/暂停按下去动的就是别人——这正是
    /// 要修的问题。反过来只显示 owner，「显示谁、控谁」就由构造保证，不需要任何折中。
    /// 切换也随之简单：新音源开播 → 系统把它设为 owner → 卡片跟过去；音源关闭 →
    /// owner 换人/落空 → 卡片换成新 owner 或清空（规则 3/4）。
    ///
    /// - Parameter audible: 系统混音当前有没有声音；nil = 没在捕获，属于「不知道」，
    ///   此时不能判暂停。出声列表非空但没声音 = app 只是占着输出流（QQ音乐暂停后
    ///   `IsRunningOutput` 不归零），要按「已暂停」展示
    private func read(audible: Bool?) -> NowPlayingInfo? {
        // 会话必须走子进程读：进程内的 `MRNowPlayingRequest` 属性**冻结在首次读取**
        // （实测 app 退出 12s 后长跑进程还报它的 bundleID，新进程立刻正确），
        // 而 C 接口在这版 macOS 上被阉（PID 恒 0、DisplayID 恒 nil），见 DEV-082。
        // 两条路都读不到 = 「不知道」，不能当成「没有音源」去清卡
        guard let session = readSession() else {
            lastReadDefinitiveEmpty = false
            logIfChanged("read 失败（子进程 + 进程内都没结果）")
            return nil
        }
        // owner 优先用 playerPath 的 client；条目在、client 读不到时用条目的 bundleID 兜
        let owner = session.owner ?? session.media?.appBundleID
        let rawActives = AudioActivityMonitor.activeApps(owner: owner)
        let actives = rawActives.filter { Self.isAllowed($0.bundleID) }
        logBlocked(session.media, rawActives: rawActives, actives: actives)
        logActives(actives, owner: owner, audible: audible)
        syncProbeTargets(actives)

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

        // 白名单 + 存活校验：owner 不在白名单 = 媒体键会路由给白名单外的 app，
        // 显示谁都控不到，宁可不出卡（核心不变式）；owner 已退出（会话残留）同理，
        // 卡片上的「打开」按钮和媒体控制都以 app 在跑为前提。
        // 「确实没有 owner」是确定状态（音源全关了），可以立即清卡；owner 存在但不可用时
        // 仍走防抖，免得白名单外的 app 在响时 owner 反复横跳让卡片闪
        guard let owner, Self.isAllowed(owner),
              let app = Self.runningApp(bundleID: owner) else {
            lastReadDefinitiveEmpty = (owner == nil)
            logIfChanged("idle owner=\(owner ?? "-")")
            return nil
        }
        lastReadDefinitiveEmpty = false

        // owner 上报了元数据：用会话信息（曲名/进度/播放态更全），控制走 MR 命令
        if let media = session.media, AudioActivityMonitor.sameApp(media.appBundleID, owner) {
            logIfChanged("media app=\(media.appBundleID ?? "-")（owner）")
            return media.setting(pid: app.processIdentifier)
        }

        // owner 不上报（QQ音乐）：身份用 AX/窗口标题兜底，控制走系统媒体键
        return audioOnlyInfo(owner: owner, app: app, actives: actives, audible: audible)
    }

    /// 让「按 app 抓音频」的探针对准**出声列表里的所有候选**（白名单最多 3 个）。
    /// 探针用来回答「卡片上这个 app 停了没有」（`deriveIsPlaying`）；
    /// 只在目标集合变化时重建捕获流（队列侧判重，别每轮都塞主线程）
    private func syncProbeTargets(_ actives: [AudioActivity]) {
        let wanted = probeEnabled
            ? Set(actives.compactMap { a in a.bundleID.map { AppAudioProbe.Target(pid: a.pid, bundleID: $0) } })
            : []
        guard wanted != probeTargets else { return }
        probeTargets = wanted
        let targets = Array(wanted)
        DispatchQueue.main.async {
            AppAudioProbe.shared.setTargets(targets)
        }
    }

    /// owner 不上报元数据时的兜底卡：曲名读 AX 播放控制栏，读不到退回窗口标题。
    /// owner 就是媒体键的路由目标，所以「卡片上是谁，点下去就控谁」，按钮不用置灰（DEV-090）
    private func audioOnlyInfo(owner: String, app: NSRunningApplication,
                               actives: [AudioActivity],
                               audible: Bool?) -> NowPlayingInfo? {
        let pid = app.processIdentifier
        let axInfo = AXMediaInfoReader.read(pid: pid)
        let title = axInfo?.title ?? WindowTitleReader.title(forPID: pid, appName: app.localizedName)
        logIfChanged("audio-only app=\(owner) title=\(title ?? "nil") n=\(actives.count) audible=\(audible.map { "\($0)" } ?? "-")")
        return NowPlayingInfo(
            title: title,
            artist: axInfo?.artist,
            album: nil,
            appBundleID: owner,
            appName: app.localizedName,
            pid: pid,
            // 它在出声列表里不代表在响：暂停后仍可能占着输出流，以「有没有声音」为准
            isPlaying: audible ?? true,
            elapsed: nil,
            duration: nil,
            control: .mediaKey
        )
    }

    /// 一次会话读取的结果。两者要分开：QQ音乐这类 app 只注册媒体键路由、不发布元数据——
    /// 它是 owner（媒体键会路由给它），但 `localNowPlayingItem` 是 nil
    private struct SessionRead {
        /// 当前 now playing owner 的 bundleID（媒体键/MR 命令的路由目标）
        var owner: String?
        /// owner 上报的条目（曲名/进度等）；没上报为 nil
        var media: NowPlayingInfo?
    }

    /// 读「系统 Now Playing」。子进程优先（唯一能拿到新鲜值的路径，~77ms，跑在轮询队列上），
    /// 失败再退回进程内——进程内的值虽然会冻结，但比什么都没有强。
    /// 返回 nil = 两条路都读不到（「不知道」），调用方不能把它当成「没有音源」
    private func readSession() -> SessionRead? {
        if let fresh = readViaSubprocess() { return fresh }
        return useSubprocess ? nil : readInProcess()
    }

    /// 出声了但还没认出是谁（进程注册比声音晚一拍）时的补查间隔；nil = 刚查过，别再查
    private func quickRetry() -> TimeInterval? {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRetryAt > 1 else { return nil }
        lastRetryAt = now
        return 0.25
    }

    private func logIfChanged(_ summary: String) {
        guard Self.debug, summary != lastDebugSummary else { return }
        lastDebugSummary = summary
        ZSLog("NowPlaying: \(summary)")
    }

    /// 白名单挡掉了谁：只在变化时打。排查「明明在放歌但卡片是空的」时，先看这条
    private func logBlocked(_ media: NowPlayingInfo?,
                            rawActives: [AudioActivity], actives: [AudioActivity]) {
        guard Self.debug else { return }
        let mediaSummary = media.flatMap { Self.isAllowed($0.appBundleID) ? nil : ($0.appBundleID ?? "?") } ?? "-"
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
        guard let info = nowPlaying, info.control != .none else { return }
        // 发送前核对一次路由目标（核心不变式的最后一道闸）：卡片是从 owner 派生的，
        // 不一致只可能是这一两秒内 owner 换人了（另一个 app 刚开播）。这时发出去控到的是别人，
        // 宁可这一下不发，先把卡片刷成新的。核对走子进程（~80ms，异步，按钮不会卡）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let freshOwner = self.readViaSubprocess()?.owner
            DispatchQueue.main.async {
                if let freshOwner, !AudioActivityMonitor.sameApp(freshOwner, info.appBundleID) {
                    if Self.debug {
                        ZSLog("NowPlaying: send \(command) 放弃 card=\(info.appBundleID ?? "-") owner=\(freshOwner)（路由目标已换人）")
                    }
                    self.tick()
                    return
                }
                self.perform(command, on: info)
            }
        }
    }

    /// 真正发命令。调用前已确认 `info` 就是当前路由目标
    private func perform(_ command: Command, on info: NowPlayingInfo) {
        // 核对期间卡片可能已经被轮询换掉了：换了就按新卡片来，别按旧对象发
        guard let cur = nowPlaying, AudioActivityMonitor.sameApp(cur.appBundleID, info.appBundleID) else {
            tick()
            return
        }
        // 播放/暂停：先把图标翻过去，再让电平/出声列表验证（DEV-085）。
        // 只翻 togglePlay——上一首/下一首不改变播放态。基线用 `cur`（最新状态），
        // 不用点击那一刻的 `info`，否则核对期间落地的轮询结果会被旧值覆盖
        switch cur.control {
        case .mediaRemote:
            guard let fn = sendCommandFn else { return }
            if command == .togglePlay { beginPendingToggle(for: cur) }
            fn(UInt32(command.rawValue), nil)
        case .mediaKey:
            if command == .togglePlay { beginPendingToggle(for: cur) }
            MediaKey.post(Self.mediaKey(for: command))
        case .none:
            return
        }
        if Self.debug { ZSLog("NowPlaying: sent \(command) via \(cur.control)") }
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

    private func readInProcess() -> SessionRead {
        guard let cls = Self.requestClass else { return SessionRead(owner: nil, media: nil) }
        // owner 单独取：QQ音乐这类 app 只注册媒体键路由、没有条目，owner 照样有值
        var owner: String?
        var appName: String?
        if cls.responds(to: Selector(("localNowPlayingPlayerPath"))),
           let path = cls.value(forKey: "localNowPlayingPlayerPath") as? NSObject,
           path.responds(to: Selector(("client"))),
           let client = path.value(forKey: "client") as? NSObject {
            if client.responds(to: Selector(("displayName"))) {
                appName = client.value(forKey: "displayName") as? String
            }
            if client.responds(to: Selector(("bundleIdentifier"))) {
                owner = client.value(forKey: "bundleIdentifier") as? String
            }
        }
        guard cls.responds(to: Selector(("localNowPlayingItem"))),
              let item = cls.value(forKey: "localNowPlayingItem") as? NSObject,
              item.responds(to: Selector(("nowPlayingInfo"))),
              let info = item.value(forKey: "nowPlayingInfo") as? [String: Any],
              let title = string(info, "kMRMediaRemoteNowPlayingInfoTitle") else {
            return SessionRead(owner: owner, media: nil)
        }
        if appName == nil, let bid = owner {
            appName = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bid }?.localizedName
        }

        let rate = double(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate")
        let isPlaying = rate.map { $0 != 0 } ?? true
        let media = NowPlayingInfo(
            title: title,
            artist: string(info, "kMRMediaRemoteNowPlayingInfoArtist"),
            album: string(info, "kMRMediaRemoteNowPlayingInfoAlbum"),
            appBundleID: owner,
            appName: appName,
            // pid 由 `read()` 统一补：那里才做白名单 + 存活校验
            pid: nil,
            isPlaying: isPlaying,
            elapsed: double(info, "kMRMediaRemoteNowPlayingInfoElapsedTime"),
            duration: double(info, "kMRMediaRemoteNowPlayingInfoDuration"),
            control: .mediaRemote
        )
        return SessionRead(owner: owner, media: media)
    }

    private func string(_ info: [String: Any], _ key: String) -> String? {
        (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func double(_ info: [String: Any], _ key: String) -> Double? {
        (info[key] as? NSNumber)?.doubleValue
    }

    // MARK: - 读取:osascript JXA 子进程(降级路径)

    /// 子进程输出格式（`␟` 分隔）：ownerBundleID ␟ 曲名 ␟ 歌手 ␟ 专辑 ␟ 条目bundleID ␟
    /// app 名 ␟ 时长 ␟ 进度 ␟ playbackRate。
    /// **owner 和条目必须分两段读**：QQ音乐是 owner 但没有条目，旧格式在 `NOITEM` 处
    /// 直接返回，owner 跟着丢了——卡片于是靠粘性记忆猜，控谁全凭运气（DEV-090）
    private func readViaSubprocess() -> SessionRead? {
        guard let out = Self.runJXA() else { return nil }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\u{241F}", omittingEmptySubsequences: false)
        guard parts.count >= 9, parts[0] != "NOCLASS" else { return nil }
        let owner = parts[0].isEmpty ? nil : String(parts[0])
        let num = { (s: Substring) -> Double? in
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : Double(t)
        }
        let title = parts[1].trimmingCharacters(in: .whitespaces)
        let media = title.isEmpty ? nil : NowPlayingInfo(
            title: title,
            artist: parts[2].isEmpty ? nil : String(parts[2]),
            album: parts[3].isEmpty ? nil : String(parts[3]),
            // 条目自己的 bundleID 读不到时归到 owner 名下，否则 `read()` 的归属校验会失配
            appBundleID: parts[4].isEmpty ? owner : String(parts[4]),
            appName: parts[5].isEmpty ? nil : String(parts[5]),
            pid: nil,
            isPlaying: num(parts[8]).map { $0 != 0 } ?? true,
            elapsed: num(parts[7]),
            duration: num(parts[6]),
            control: .mediaRemote
        )
        return SessionRead(owner: owner, media: media)
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
      function s(v) { return (v && !v.isNil() && typeof v.js !== 'undefined') ? String(v.js) : ''; }
      // owner（媒体键的路由目标）先取：QQ音乐这类 app 只注册路由、没有条目，
      // 它才是「按下去会控到谁」的答案，不能因为 item 是 nil 就丢掉
      var owner = '';
      try {
        var pc = cls.localNowPlayingPlayerPath.client;
        owner = pc.bundleIdentifier && !pc.bundleIdentifier.isNil() ? pc.bundleIdentifier.js : '';
      } catch (e) {}
      var t = '', artist = '', album = '', bid = '', app = '', dur = '', ela = '', rate = '';
      try {
        var item = cls.localNowPlayingItem;
        if (!item.isNil()) {
          var info = item.nowPlayingInfo;
          if (!info.isNil()) {
            t = s(info.valueForKey('kMRMediaRemoteNowPlayingInfoTitle'));
            artist = s(info.valueForKey('kMRMediaRemoteNowPlayingInfoArtist'));
            album = s(info.valueForKey('kMRMediaRemoteNowPlayingInfoAlbum'));
            dur = s(info.valueForKey('kMRMediaRemoteNowPlayingInfoDuration'));
            ela = s(info.valueForKey('kMRMediaRemoteNowPlayingInfoElapsedTime'));
            rate = s(info.valueForKey('kMRMediaRemoteNowPlayingInfoPlaybackRate'));
          }
        }
        var c = cls.localNowPlayingPlayerPath.client;
        app = c.displayName && !c.displayName.isNil() ? c.displayName.js : '';
        bid = s(c.bundleIdentifier);
      } catch (e) {}
      return [owner, t, artist, album, bid, app, dur, ela, rate].join('␟');
    }
    """
}
