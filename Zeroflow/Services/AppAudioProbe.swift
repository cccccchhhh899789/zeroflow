import AppKit
import AudioToolbox
import CoreMedia
import ScreenCaptureKit

/// 「这一个 app 到底有没有在出声」——按 app 抓音频（ScreenCaptureKit 的 `includingApplications` 过滤器）。
///
/// 为什么必须按 app 抓：系统混音是所有 app 的叠加，多个声源同时响时无法归属；
/// `kAudioProcessPropertyIsRunningOutput` 又只是布尔值，而且**暂停后不一定归零**
/// （浏览器、AVAudioPlayer 这类暂停后仍占着输出流，见 DEV-075/079）。
/// 于是「卡片显示的这个 app 停了没有」用公开 API 判不出来——只能单独听它。
///
/// 代价：多一条 16×16@1fps 的捕获流（只开音频），复用截图已有的屏幕录制权限。
/// 只给「当前播放器」一个 app 建流，切人时先停旧的再建新的。
final class AppAudioProbe: NSObject, ObservableObject {
    static let shared = AppAudioProbe()

    /// 目标 app 当前是否在出声。nil = 还没测出来（流没起来 / 拿不到该 app 的捕获对象），
    /// 调用方要退回旧规则，别把它当成「暂停」
    @Published private(set) var isSounding: Bool?

    /// 正在探测哪个 app（`sounding(for:)` 用它确认归属，避免拿 A 的电平去判 B）
    private(set) var targetBundleID: String?
    private(set) var targetPID: pid_t?

    /// 一段静音多久算「停了」。暂停是立刻的，但 buffer 里可能还压着尾巴，留 0.3s
    private static let hangover: TimeInterval = 0.3
    /// 峰值阈值（≈ -66dBFS）：轻一点的曲子也算在响，别把「小声」判成「停」
    private static let peakThreshold: Float = 0.0005

    private var stream: SCStream?
    /// 每次 setTarget 自增，用来丢弃过期的异步启动结果
    private var generation = 0
    /// 最近一次听到声音的时刻（音频队列写、主线程读，单个 Double 无需加锁，同 AudioSpectrumMonitor）
    private var lastSoundAt: CFAbsoluteTime = 0
    /// 这条流有没有真的收到过音频 buffer。**没收到过就绝不说「静音」**：
    /// 分不清「它本来就静着」和「按 app 捕获对它是瞎的」，说错了会把正在播的卡片判成暂停。
    /// 只有先听见过它出声，后面的「静音」才可信
    private var sawAudioBuffer = false
    private var startedAt: CFAbsoluteTime = 0
    private var timer: Timer?
    private let queue = DispatchQueue(label: "zeroflow.notch.appaudio", qos: .utility)
    private let ablBuffer = AudioBufferList.allocate(maximumBuffers: 2)

    private override init() {
        super.init()
    }

    deinit {
        free(ablBuffer.unsafeMutablePointer)
    }

    /// 换探测目标；pid 为 nil 表示停止探测（面板收起 / 没有当前播放器）。主线程调用
    func setTarget(pid: pid_t?, bundleID: String?) {
        guard pid != targetPID else {
            targetBundleID = bundleID
            return
        }
        stop()
        targetPID = pid
        targetBundleID = bundleID
        guard let pid else { return }
        start(pid: pid)
    }

    /// 这条电平是不是属于 `bundleID` 这个 app；nil = 不归它管，调用方别用
    func sounding(for bundleID: String?) -> Bool? {
        guard let bundleID, AudioActivityMonitor.sameApp(targetBundleID, bundleID) else { return nil }
        return isSounding
    }

    // MARK: - 启停

    private func start(pid: pid_t) {
        generation += 1
        let gen = generation
        isSounding = nil
        lastSoundAt = 0
        sawAudioBuffer = false
        startedAt = CFAbsoluteTimeGetCurrent()
        startTimer()
        Task { [weak self] in
            guard let self else { return }
            do {
                // onScreenWindowsOnly: false —— 最小化/后台的播放器也要能抓到
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                  onScreenWindowsOnly: false)
                guard gen == self.generation else { return }
                guard let app = content.applications.first(where: { $0.processID == pid }),
                      let display = content.displays.first else {
                    // 拿不到该 app 的捕获对象（没有窗口 / 已被系统过滤）：交给调用方退回旧规则
                    self.publish(nil, gen: gen)
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

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                guard gen == self.generation else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                if NowPlayingMonitor.debug { ZSLog("AppAudio: 探测 pid=\(pid) bundle=\(self.targetBundleID ?? "-")") }
            } catch {
                if NowPlayingMonitor.debug { ZSLog("AppAudio: 启动失败 \(error.localizedDescription)") }
                self.publish(nil, gen: gen)
            }
        }
    }

    private func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        isSounding = nil
        lastSoundAt = 0
        sawAudioBuffer = false
        startedAt = 0
    }

    /// 10Hz 重算：SCK 在完全静音时可能不再投递 buffer，只靠回调会让状态卡在「在响」
    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.targetPID != nil else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if self.lastSoundAt > 0, now - self.lastSoundAt < Self.hangover {
                self.publish(true, gen: self.generation)
            } else if self.sawAudioBuffer, self.startedAt > 0, now - self.startedAt > Self.hangover {
                self.publish(false, gen: self.generation)
            } else {
                self.publish(nil, gen: self.generation)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func publish(_ value: Bool?, gen: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.generation, self.isSounding != value else { return }
            self.isSounding = value
        }
    }
}

extension AppAudioProbe: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablBuffer.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, ablBuffer.count > 0 else { return }
        sawAudioBuffer = true
        let buffer = ablBuffer[0]
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
        if peak > Self.peakThreshold { lastSoundAt = CFAbsoluteTimeGetCurrent() }
    }
}
