import AppKit
import AudioToolbox
import CoreMedia
import ScreenCaptureKit

/// 「哪些 app 到底在出声」——按 app 分别抓音频（ScreenCaptureKit 的 `includingApplications` 过滤器）。
///
/// 为什么必须按 app 抓：系统混音是所有 app 的叠加，多个声源同时响时无法归属；
/// `kAudioProcessPropertyIsRunningOutput` 又只是布尔值，而且**暂停后不一定归零**
/// （浏览器、AVAudioPlayer 这类暂停后仍占着输出流，见 DEV-075/079）。
/// 于是「某个 app 停了没有」用公开 API 判不出来——只能单独听它。
///
/// **同时探所有候选**（DEV-089）：只探「当前播放器」时，多音源下没法回答
/// 「另一个 app 是不是正在响」，换人就只能靠猜，卡片会粘在暂停的那个 app 上。
/// 代价是 N 条 16×16@1fps 的纯音频捕获流（白名单最多 3 个 app，每条约等于一个极小的音频会话）。
/// 只给「出声列表里的 app」建流，离开列表就拆——不在列表里 = 肯定没在输出，不必听。
final class AppAudioProbe: NSObject, ObservableObject {
    static let shared = AppAudioProbe()

    /// 一个探测目标（pid 是宿主 app 的 pid，helper 已由 `AudioActivityMonitor` 归并）
    struct Target: Hashable {
        let pid: pid_t
        let bundleID: String
    }

    /// bundleID → 是否在出声。**只放有确凿证据的项**：听见过它出声之后，后面的「静」才可信；
    /// 从没收到过 buffer 的 app 不进表（分不清「它本来静着」和「按 app 捕获对它是瞎的」）
    @Published private(set) var levels: [String: Bool] = [:]

    /// 一段静音多久算「停了」。暂停是立刻的，但 buffer 里可能还压着尾巴，留 0.3s
    private static let hangover: TimeInterval = 0.3
    /// 峰值阈值（≈ -66dBFS）：轻一点的曲子也算在响，别把「小声」判成「停」
    private static let peakThreshold: Float = 0.0005

    /// 单条捕获流 + 它的电平状态
    private final class Probe {
        let pid: pid_t
        let bundleID: String
        var stream: SCStream?
        var sink: Sink?
        /// 每次 start/stop 自增，用来丢弃过期的异步启动结果
        var generation = 0
        var startedAt: CFAbsoluteTime = 0
        /// 最近一次听到声音的时刻（音频队列写、主线程读，单个 Double 无需加锁，同 AudioSpectrumMonitor）
        var lastSoundAt: CFAbsoluteTime = 0
        /// 这条流有没有真的收到过音频 buffer。**没收到过就绝不说「静音」**
        var sawAudioBuffer = false
        /// 最近一次发布的判定值，用来判「变了没有」
        var value: Bool?
        private let abl = AudioBufferList.allocate(maximumBuffers: 2)

        init(pid: pid_t, bundleID: String) {
            self.pid = pid
            self.bundleID = bundleID
        }

        deinit {
            free(abl.unsafeMutablePointer)
        }

        func stop() {
            generation += 1
            startedAt = 0
            lastSoundAt = 0
            sawAudioBuffer = false
            value = nil
            if let stream { Task { try? await stream.stopCapture() } }
            stream = nil
            sink = nil
        }

        func ingest(_ sampleBuffer: CMSampleBuffer) {
            guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
            var blockBuffer: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: abl.unsafeMutablePointer,
                bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2),
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr, abl.count > 0 else { return }
            sawAudioBuffer = true
            let buffer = abl[0]
            guard let data = buffer.mData, buffer.mDataByteSize >= 4 else { return }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: count)
            // 只要「有没有能量」，不跑 FFT：跳采一遍峰值就够，别为这个再占一份 CPU
            var peak: Float = 0
            var i = 0
            while i < count {
                let v = abs(floats[i])
                if v > peak { peak = v }
                i += 8
            }
            if peak > AppAudioProbe.peakThreshold { lastSoundAt = CFAbsoluteTimeGetCurrent() }
        }
    }

    /// 每条流一个回调代理，把 buffer 转给对应的 Probe（Probe 弱引用，不成环）
    private final class Sink: NSObject, SCStreamOutput {
        weak var probe: Probe?

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                    of type: SCStreamOutputType) {
            guard type == .audio else { return }
            probe?.ingest(sampleBuffer)
        }
    }

    private var probes: [String: Probe] = [:]
    private var timer: Timer?
    /// 给轮询队列读的快照（`updateCurrent` 在后台判「谁在响」）
    private var snapshot: [String: Bool] = [:]
    private let snapshotLock = NSLock()
    private let queue = DispatchQueue(label: "zeroflow.notch.appaudio", qos: .utility)

    private override init() {
        super.init()
    }

    // MARK: - 目标维护

    /// 换一组探测目标。主线程调用；只重建有变化的那几条流，别每次全拆全建
    func setTargets(_ targets: [Target]) {
        let wanted = Set(targets)
        // 拆掉不再需要的（Swift 字典是值语义，边遍历边删是安全的）
        for (bid, probe) in probes where !wanted.contains(Target(pid: probe.pid, bundleID: bid)) {
            probe.stop()
            probes.removeValue(forKey: bid)
        }
        // 建新的：bundle 变了或 pid 变了（app 重启）
        var added: [Probe] = []
        for target in wanted {
            if let existing = probes[target.bundleID] {
                guard existing.pid != target.pid else { continue }
                existing.stop()
                probes.removeValue(forKey: target.bundleID)
            }
            let probe = Probe(pid: target.pid, bundleID: target.bundleID)
            probes[target.bundleID] = probe
            added.append(probe)
        }
        for probe in added { start(probe) }
        updateTimer()
        publishLevels()
    }

    /// 这条电平是不是属于 `bundleID` 这个 app；nil = 判不出来，调用方别用
    func sounding(for bundleID: String?) -> Bool? {
        guard let bundleID else { return nil }
        snapshotLock.lock()
        let snap = snapshot
        snapshotLock.unlock()
        if let exact = snap[bundleID] { return exact }
        // helper / 扩展进程的 bundle 前缀归并到宿主
        for (bid, value) in snap where AudioActivityMonitor.sameApp(bid, bundleID) { return value }
        return nil
    }

    /// 探针确认「正在出声」的 bundleID 集合（任意线程可读，只用于诊断日志）
    var soundingBundleIDs: Set<String> {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return Set(snapshot.filter { $0.value }.keys)
    }

    // MARK: - 启停

    private func start(_ probe: Probe) {
        probe.generation += 1
        let gen = probe.generation
        probe.startedAt = CFAbsoluteTimeGetCurrent()
        probe.lastSoundAt = 0
        probe.sawAudioBuffer = false
        probe.value = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                // onScreenWindowsOnly: false —— 最小化/后台的播放器也要能抓到
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                  onScreenWindowsOnly: false)
                guard gen == probe.generation else { return }
                guard let app = content.applications.first(where: { $0.processID == probe.pid }),
                      let display = content.displays.first else {
                    // 拿不到该 app 的捕获对象（没有窗口 / 已被系统过滤）：这条流不建，
                    // `sounding(for:)` 保持 nil，调用方退回旧规则
                    if NowPlayingMonitor.debug {
                        ZSLog("AppAudio: 拿不到捕获对象 pid=\(probe.pid) bundle=\(probe.bundleID)")
                    }
                    return
                }
                let filter = SCContentFilter(display: display,
                                             including: [app],
                                             exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                // 只要音频：视频压到最小 + 1fps（SCK 不允许关掉视频轨）
                config.width = 16
                config.height = 16
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.showsCursor = false

                let sink = Sink()
                sink.probe = probe
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                guard gen == probe.generation else {
                    try? await stream.stopCapture()
                    return
                }
                probe.stream = stream
                probe.sink = sink
                if NowPlayingMonitor.debug {
                    ZSLog("AppAudio: 探测 pid=\(probe.pid) bundle=\(probe.bundleID)")
                }
            } catch {
                if NowPlayingMonitor.debug {
                    ZSLog("AppAudio: 启动失败 \(probe.bundleID) \(error.localizedDescription)")
                }
            }
        }
    }

    /// 10Hz 重算：SCK 在完全静音时可能不再投递 buffer，只靠回调会让状态卡在「在响」
    private func updateTimer() {
        if probes.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.recompute()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func recompute() {
        let now = CFAbsoluteTimeGetCurrent()
        var changed = false
        for probe in probes.values {
            let value: Bool?
            if probe.lastSoundAt > 0, now - probe.lastSoundAt < Self.hangover {
                value = true
            } else if probe.sawAudioBuffer, probe.startedAt > 0, now - probe.startedAt > Self.hangover {
                value = false
            } else {
                value = nil
            }
            if probe.value != value {
                probe.value = value
                changed = true
            }
        }
        if changed { publishLevels() }
    }

    /// 主线程：把各条流的判定汇总成一张表，同步给后台快照再发 UI
    private func publishLevels() {
        var dict: [String: Bool] = [:]
        for probe in probes.values {
            if let value = probe.value { dict[probe.bundleID] = value }
        }
        snapshotLock.lock()
        snapshot = dict
        snapshotLock.unlock()
        guard dict != levels else { return }
        levels = dict
    }
}
