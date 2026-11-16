import Darwin
import Foundation

/// CPU 温度读取（IOKit 私有 API，运行时 dlsym，与 `CGSWindowServer` 同款模式）。
///
/// `IOHIDEventSystemClient` 以 Monitor 类型创建客户端，匹配 AppleSMC 的传感器服务
/// （PrimaryUsagePage 0xff00 / PrimaryUsage 5、6），按 `Product` 前缀筛出 `PMU tdie*`
/// （Apple Silicon 每个核/核簇一个 die 温度传感器，M5 实测 14 个），读
/// `kIOHIDEventTypeTemperature` 事件值，取最高者作为 CPU 热点温度。
///
/// 免 root、免授权（不匹配键盘/指针等输入设备，不触发 TCC）；Intel 机器没有该传感器组
/// → `isAvailable == false`，调用方显示「—」。任一符号缺失同样降级，不崩。
final class CPUTemperatureReader {
    static let shared = CPUTemperatureReader()

    // MARK: - dlsym 函数类型

    private typealias CreateWithTypeFn = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingMultipleFn = @convention(c) (CFTypeRef, CFArray) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias ServiceCopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias ServiceCopyEventFn = @convention(c) (CFTypeRef, Int64, Int64, Int64) -> Unmanaged<CFTypeRef>?
    private typealias EventGetFloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    private struct Bridge {
        let create: CreateWithTypeFn
        let setMatchingMultiple: SetMatchingMultipleFn
        let copyServices: CopyServicesFn
        let serviceCopyProperty: ServiceCopyPropertyFn
        let serviceCopyEvent: ServiceCopyEventFn
        let eventGetFloatValue: EventGetFloatValueFn
    }

    /// `kIOHIDEventSystemClientTypeMonitor`
    private static let clientTypeMonitor: Int32 = 1
    /// `kIOHIDEventTypeTemperature`
    private static let temperatureEventType: Int64 = 15
    /// `IOHIDEventFieldBase(kIOHIDEventTypeTemperature) | kIOHIDEventFieldTemperatureLevel`
    private static let temperatureField: Int32 = 15 << 16
    /// Apple Silicon 的 die 温度传感器名前缀（另有 `PMU tdev*`/`PMU tcal`，后者是标定值不随负载变）
    private static let sensorPrefix = "PMU tdie"
    /// 连续读不到值（睡眠唤醒后 client 可能失效）时重建传感器列表的阈值
    private static let rebuildThreshold = 5

    private let bridge: Bridge?
    private let lock = NSLock()
    /// 客户端与传感器列表常驻复用（创建一次约 15ms，2s 一采样不该每次重建）；
    /// 单例活到进程结束，client 不主动 release（避免 service 引用悬空）
    private var client: CFTypeRef?
    private var sensors: [CFTypeRef] = []
    private var resolved = false
    private var consecutiveMisses = 0

    var isAvailable: Bool { bridge != nil }

    private init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            ZSLog("CPUTemperatureReader: dlopen IOKit failed")
            bridge = nil
            return
        }
        func sym<T>(_ name: String) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let create: CreateWithTypeFn = sym("IOHIDEventSystemClientCreateWithType"),
              let setMatchingMultiple: SetMatchingMultipleFn = sym("IOHIDEventSystemClientSetMatchingMultiple"),
              let copyServices: CopyServicesFn = sym("IOHIDEventSystemClientCopyServices"),
              let serviceCopyProperty: ServiceCopyPropertyFn = sym("IOHIDServiceClientCopyProperty"),
              let serviceCopyEvent: ServiceCopyEventFn = sym("IOHIDServiceClientCopyEvent"),
              let eventGetFloatValue: EventGetFloatValueFn = sym("IOHIDEventGetFloatValue")
        else {
            ZSLog("CPUTemperatureReader: symbols missing, temperature unavailable")
            bridge = nil
            return
        }
        bridge = Bridge(create: create,
                        setMatchingMultiple: setMatchingMultiple,
                        copyServices: copyServices,
                        serviceCopyProperty: serviceCopyProperty,
                        serviceCopyEvent: serviceCopyEvent,
                        eventGetFloatValue: eventGetFloatValue)
    }

    /// 当前 CPU 热点温度（°C）；nil = 平台不支持或本轮读不到
    func readCelsius() -> Double? {
        guard let bridge else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if !resolved { resolveSensors(bridge) }
        guard !sensors.isEmpty else { return nil }

        var hottest: Double = 0
        for service in sensors {
            guard let eventRef = bridge.serviceCopyEvent(service, Self.temperatureEventType, 0, 0) else { continue }
            let event = eventRef.takeRetainedValue()
            let value = bridge.eventGetFloatValue(event, Self.temperatureField)
            if value.isFinite, value > 0 { hottest = max(hottest, value) }
        }
        if hottest > 0 {
            consecutiveMisses = 0
            return hottest
        }
        consecutiveMisses += 1
        if consecutiveMisses >= Self.rebuildThreshold {
            // 传感器列表或 client 失效：下次调用重建一次
            resolved = false
            sensors.removeAll()
            client = nil
            consecutiveMisses = 0
        }
        return nil
    }

    /// 一次性筛出 `PMU tdie*` 传感器（调用方已持锁）
    private func resolveSensors(_ bridge: Bridge) {
        resolved = true
        guard let clientRef = bridge.create(kCFAllocatorDefault, Self.clientTypeMonitor, nil) else {
            ZSLog("CPUTemperatureReader: client unavailable")
            return
        }
        let client = clientRef.takeRetainedValue()
        self.client = client
        let matching: [[String: Any]] = [
            ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5],
            ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 6],
        ]
        bridge.setMatchingMultiple(client, matching as CFArray)
        guard let servicesRef = bridge.copyServices(client) else { return }
        let services = servicesRef.takeRetainedValue() as [AnyObject]
        for service in services {
            guard let productRef = bridge.serviceCopyProperty(service, "Product" as CFString) else { continue }
            let product = productRef.takeRetainedValue() as? String ?? ""
            if product.hasPrefix(Self.sensorPrefix) { sensors.append(service) }
        }
        ZSLog("CPUTemperatureReader: \(sensors.count) die sensors")
    }
}
