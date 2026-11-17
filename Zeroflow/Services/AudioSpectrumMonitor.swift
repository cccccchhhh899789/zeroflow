import AppKit
import Accelerate
import AudioToolbox
import CoreMedia
import ScreenCaptureKit

/// 「正在播放」卡片的音频频谱。
///
/// 数据源走 ScreenCaptureKit 的音频捕获（`capturesAudio`）而不是 CoreAudio 的 process tap：
/// 前者复用截图已有的「屏幕录制」权限，实测 CLI 下 process tap 能建成功但读出来全是静音
/// （需要单独的音频捕获授权，且不弹窗、静默失败）；后者零成本零权限但拿不到真实波形。
///
/// 只捕获音频、视频按 1fps 最小尺寸跑，减少无谓开销；频谱在音频回调的后台队列里算，
/// 算完再回主线程发布，避免 30fps 的 FFT 卡住 UI。
final class AudioSpectrumMonitor: NSObject, ObservableObject {
    static let shared = AudioSpectrumMonitor()

    /// 频段数（16 段够看，再多在 300pt 宽里就糊了）
    static let bandCount = 16

    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: bandCount)
    /// 捕获是否真的在跑（权限被拒 / 起不来时用来降级成静态波形图标）
    @Published private(set) var isCapturing = false
    /// 系统混音当前有没有声音。**这就是「有没有在播」的真相**：有声音 = 在播，没声音 = 暂停。
    /// 带 `audibleHangover` 保持，避免曲间空隙/淡出把状态闪断。
    /// 「正在播放」卡片的播放态直接由它驱动（见 DEV-075），不再靠猜或本地翻转。
    @Published private(set) var isAudible = false

    /// 最近一次「确实有声」的时刻（音频队列写、主线程读，单个 Double 无需加锁）
    private var lastAudibleFrame: CFAbsoluteTime = 0
    /// 连续多少帧是**数字静音**（-100dB 以下，只有真正停掉输出才会出现）。
    /// 暂停就是这个特征：不用等 0.35s 保持期，几帧内就能判出暂停，图标跟手
    private var silentFrames = 0
    /// 判定「数字静音」需要连续几帧（≈100ms，挡掉偶发的空 buffer）
    private static let hardSilentFrames = 3

    private var stream: SCStream?
    private var starting = false
    /// 兜底计时器：SCK 在完全静音时可能不再投递音频 buffer（`analyze` 不跑），
    /// 只靠回调算 `isAudible` 会卡在「在播」不动。10Hz 重算一次，让状态自己过期
    private var silenceTimer: Timer?
    private let queue = DispatchQueue(label: "zeroflow.notch.spectrum", qos: .userInitiated)

    // FFT 预分配（回调在后台队列，不能每帧临时分配）
    private let fftLog2n: vDSP_Length = 10
    private var fftSize: Int { 1 << Int(fftLog2n) }
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var samples: [Float] = []
    private var windowed: [Float] = []
    private var real: [Float] = []
    private var imag: [Float] = []
    private var magnitudes: [Float] = []
    /// 每个频段的显示值（0…1），带衰减，避免跳得太生硬
    private var smoothed: [Float] = []
    /// 自适应参考顶（dB）：音乐绝对量纲跟音量/设备差几十 dB，用滚动峰值当基准才不会全满或全灭
    private var dbPeak: Float = -100
    /// 复用的 AudioBufferList，避免每个回调都 malloc
    private let ablBuffer = AudioBufferList.allocate(maximumBuffers: 2)
    private var lastPublish: CFAbsoluteTime = 0

    /// 判定「这一段是数字静音」的阈值：真静音经过 FFT 后落在 -140dB 附近
    private static let silenceDb: Float = -100
    /// 显示动态范围（dB）：参考顶往下这么多 dB 对应 1 → 0
    private static let dynamicRangeDb: Float = 42
    /// 高频补偿（dB）：音乐能量天然集中在低频，不补偿的话右半边永远是平的，看着像坏了
    private static let tiltDb: Float = 9
    /// 「有声」的保持时长：淡出/曲间空隙不该把状态闪成暂停
    private static let audibleHangover: TimeInterval = 0.35

    private override init() {
        super.init()
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        samples = [Float](repeating: 0, count: fftSize)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        smoothed = [Float](repeating: 0, count: Self.bandCount)
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
        free(ablBuffer.unsafeMutablePointer)
    }

    // MARK: - 启停

    func setActive(_ active: Bool) {
        if active {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard stream == nil, !starting else { return }
        starting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                  onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    self.starting = false
                    return
                }
                // 整屏过滤 = 抓系统混音（所有 app 的输出），正是「正在播放」要听的
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                // 只要音频：视频压到最小 + 1fps（SCK 不允许关掉视频轨，只能这么省）
                config.width = 16
                config.height = 16
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.showsCursor = false

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                self.stream = stream
                self.starting = false
                self.isCapturing = true
                // 状态交给第一帧音频定：不预设「在播」也不预设「暂停」，
                // 否则卡片刚弹出会先闪一下反状态（真在播时第一帧≈50ms 就到）
                self.lastAudibleFrame = 0
                self.silentFrames = 0
                self.isAudible = false
                self.startSilenceTimer()
                if NowPlayingMonitor.debug { ZSLog("Spectrum: 已启动") }
            } catch {
                self.starting = false
                self.isCapturing = false
                ZSLog("Spectrum: 启动失败 \(error.localizedDescription)")
            }
        }
    }

    private func stop() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard let stream else {
            starting = false
            return
        }
        self.stream = nil
        isCapturing = false
        Task {
            try? await stream.stopCapture()
            if NowPlayingMonitor.debug { ZSLog("Spectrum: 已停止") }
        }
        smoothed = [Float](repeating: 0, count: Self.bandCount)
        dbPeak = Self.silenceDb
        lastAudibleFrame = 0
        silentFrames = 0
        DispatchQueue.main.async {
            self.levels = Array(repeating: 0, count: Self.bandCount)
            self.isAudible = false
        }
    }

    // MARK: - 音频回调 → FFT

    /// 静音兜底：SCK 静音时可能不再投递 buffer，靠 10Hz 重算让 `isAudible` 能自己过期
    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isCapturing else { return }
            let audible = self.audibleNow
            if self.isAudible != audible { self.isAudible = audible }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func analyze(_ buffer: CMSampleBuffer) {
        guard buffer.isValid,
              CMSampleBufferGetNumSamples(buffer) > 0 else { return }

        // 用 ABL 取第一声道数据：planar（每声道一个 buffer）和 interleaved（一个 buffer 多声道）
        // 都能拿到正确的连续样本，比直接 CMBlockBufferGetDataPointer 安全
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablBuffer.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, ablBuffer.count > 0 else { return }
        let audioBuffer = ablBuffer[0]
        guard let data = audioBuffer.mData, audioBuffer.mDataByteSize >= 4 else { return }

        let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let floats = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: count)
        // interleaved 时按声道数跳采，planar 时步长天然是 1
        let stride = max(1, Int(audioBuffer.mNumberChannels))
        let take = min(count / stride, fftSize)
        guard take > 64 else { return }
        for i in 0..<take { samples[i] = floats[i * stride] }
        if take < fftSize {
            for i in take..<fftSize { samples[i] = 0 }
        }

        guard let setup = fftSetup else { return }
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { typed in
                        vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, fftLog2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // 按对数分桶（低频窄、高频宽），取每桶均值再转 dB
        var dbs = [Float](repeating: Self.silenceDb, count: Self.bandCount)
        var topDb = Self.silenceDb
        for b in 0..<Self.bandCount {
            let low = Int(pow(Double(half), Double(b) / Double(Self.bandCount)))
            let high = max(low + 1, Int(pow(Double(half), Double(b + 1) / Double(Self.bandCount))))
            let upper = min(high, half)
            guard upper > low else { continue }
            var sum: Float = 0
            for i in low..<upper { sum += magnitudes[i] }
            let average = sum / Float(upper - low)
            // zrip 的结果要除以 2 才是幅度量纲；取对数压动态范围；
            // 再按频段线性加一点补偿（高频少能量），让整条频谱都在动
            let tilt = Self.tiltDb * Float(b) / Float(max(1, Self.bandCount - 1))
            let db = 20 * log10(max(average / 2, 1e-7)) + tilt
            dbs[b] = db
            topDb = max(topDb, db)
        }

        updateLevels(dbs: dbs, topDb: topDb)

        // 限到 30fps 发布，别让 SwiftUI 每帧都重绘
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPublish > 1.0 / 30.0 else { return }
        lastPublish = now
        let snapshot = smoothed.map { CGFloat($0) }
        let audible = audibleNow
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.levels = snapshot
            if self.isAudible != audible { self.isAudible = audible }
        }
    }

    /// 当前是否该判「有声」：数字静音立即否，否则看 0.35s 保持期
    private var audibleNow: Bool {
        guard silentFrames < Self.hardSilentFrames else { return false }
        return lastAudibleFrame > 0 && CFAbsoluteTimeGetCurrent() - lastAudibleFrame < Self.audibleHangover
    }

    /// 自适应归一化 + 上升快下落慢的包络
    private func updateLevels(dbs: [Float], topDb: Float) {
        if topDb <= Self.silenceDb {
            // 静音：直接衰减到底，否则参考顶会一路掉、把噪声抬成满格
            silentFrames += 1
            for b in 0..<Self.bandCount { smoothed[b] *= 0.8 }
            dbPeak = max(Self.silenceDb, dbPeak - 1.5)
            return
        }
        silentFrames = 0
        // 抬 10dB 才算「有声」，免得底噪/极轻的杂音把静音计时一直续上
        if topDb > Self.silenceDb + 10 { lastAudibleFrame = CFAbsoluteTimeGetCurrent() }
        // 参考顶：立刻跟随新的更高峰，回落时每帧最多降 0.4dB（≈ 12dB/s）
        dbPeak = max(topDb, dbPeak - 0.4)
        // 参考顶别沉得太深，否则很安静的一段里噪声会被放大成满格
        dbPeak = max(dbPeak, Self.silenceDb + 40)
        let floorDb = dbPeak - Self.dynamicRangeDb
        for b in 0..<Self.bandCount {
            let level = min(1, max(0, (dbs[b] - floorDb) / Self.dynamicRangeDb))
            smoothed[b] = level > smoothed[b] ? level : smoothed[b] * 0.75 + level * 0.25
        }
    }
}

extension AudioSpectrumMonitor: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        analyze(sampleBuffer)
    }
}
