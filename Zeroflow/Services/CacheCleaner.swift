import Darwin
import Foundation

/// 「一键清理」：后台清理四类可丢弃的缓存/日志目录，并释放本应用的进程内缓存。
///
/// 清理范围（全部是「删掉会自动重建」的目录，逐子项删、不删根目录本身）：
/// 1. `~/Library/Caches/*`
/// 2. `~/Library/Containers/<bundle-id>/Data/Library/Caches/*`（沙盒 App 的缓存）
/// 3. `~/Library/Logs/*`（含 `DiagnosticReports` 崩溃/诊断报告）
///
/// 安全边界（与 `personal_files_safety` 一致）：
/// - 不碰 `/Library/Caches`（系统级，需 root）、不碰 Application Support / Documents
///   （Zeroflow 自己的剪贴板历史与图片在 Application Support，不受影响）；
/// - 不跟随符号链接（只跳过，不删链接指向的目标）；
/// - 跳过最近 10 分钟内修改过的项（可能正被某个 App 写入）；
/// - 逐项容错：某项删除失败（权限/占用）只跳过，不中断整体。
///
/// 代价：相关 App 冷启动变慢、需要重建缓存；删除不会丢用户数据。
final class CacheCleaner: ObservableObject {
    static let shared = CacheCleaner()

    enum State: Equatable {
        case idle
        /// 清理进行中
        case running
        /// 清理完成；freed = 释放的字节数（0 = 没有可清理项）
        case finished(freed: Int64)
    }

    /// 清理结果在按钮上停留的时长（s），之后回到 idle 文案
    private static let resultLinger: TimeInterval = 4
    /// 最近写入窗口：修改时间晚于此值的项视为「正在使用」，跳过
    private static let recentWriteWindow: TimeInterval = 600

    @Published private(set) var state: State = .idle

    private var resetWorkItem: DispatchWorkItem?

    private init() {}

    /// 开始清理；已在清理中则忽略（防重复点击）
    func clean() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != .running else { return }
            self.resetWorkItem?.cancel()
            self.resetWorkItem = nil
            self.state = .running
            DispatchQueue.global(qos: .utility).async { [self] in
                let probe = MemoryProbe.isLoggingEnabled
                if probe { MemoryProbe.log("clean-before") }
                var freed: Int64 = 0
                let fm = FileManager.default
                for root in Self.cleanRoots(fm: fm) {
                    freed += Self.cleanDirectory(root, fm: fm)
                }
                // 把本进程 malloc 的空闲页归还系统：这是真正能降低 footprint 的一步
                // （磁盘缓存被删、对象释放后，页仍留在 malloc free list 里）
                _ = malloc_zone_pressure_relief(nil, 0)
                // 单例常驻，闭包强引用 self 无循环风险（执行完即释放）
                DispatchQueue.main.async {
                    // 进程内缓存（缩略图 / App 图标）在主线程清，避免与绘制并发
                    WindowThumbnailer.shared.invalidateCache()
                    AppIconCache.shared.clearCache()
                    if probe {
                        MemoryProbe.log("clean-after")
                        // 遍历目录的临时对象释放后再采一次，区分「清理真实收益」与「过程开销」
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            MemoryProbe.log("clean-settled")
                        }
                    }
                    self.state = .finished(freed: freed)
                    let item = DispatchWorkItem { [weak self] in
                        guard let self, case .finished = self.state else { return }
                        self.state = .idle
                    }
                    self.resetWorkItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.resultLinger, execute: item)
                }
            }
        }
    }

    // MARK: - 清理范围（后台线程）

    /// 清理根目录：用户缓存、各沙盒容器的缓存、用户日志目录
    private static func cleanRoots(fm: FileManager) -> [URL] {
        var roots: [URL] = []
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(caches)
        }
        if let library {
            let logs = library.appendingPathComponent("Logs", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: logs.path, isDirectory: &isDir), isDir.boolValue {
                roots.append(logs)
            }
            // 沙盒 App 的缓存：~/Library/Containers/<id>/Data/Library/Caches
            let containers = library.appendingPathComponent("Containers", isDirectory: true)
            let entries = (try? fm.contentsOfDirectory(at: containers,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? []
            for container in entries {
                let caches = container.appendingPathComponent("Data/Library/Caches", isDirectory: true)
                var containerIsDir: ObjCBool = false
                if fm.fileExists(atPath: caches.path, isDirectory: &containerIsDir), containerIsDir.boolValue {
                    roots.append(caches)
                }
            }
        }
        return roots
    }

    /// 删除一个根目录下的直接子项，返回累计释放字节数
    private static func cleanDirectory(_ root: URL, fm: FileManager) -> Int64 {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: keys,
                                                        options: [.skipsSubdirectoryDescendants])
        else { return 0 }

        let cutoff = Date().addingTimeInterval(-recentWriteWindow)
        var freed: Int64 = 0
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // 符号链接：跳过（避免删到链接目标）
            if values.isSymbolicLink == true { continue }
            // 刚被写过：可能正在使用，跳过
            if let modified = values.contentModificationDate, modified > cutoff { continue }
            let size = allocatedSize(of: url, fm: fm)
            if (try? fm.removeItem(at: url)) != nil { freed += size }
        }
        return freed
    }

    /// 递归累计分配大小（失败项按 0 计）；不跟随符号链接
    private static func allocatedSize(of url: URL, fm: FileManager) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: keys,
                                             options: [],
                                             errorHandler: nil)
        else { return size(of: url) }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            total += size(of: item)
        }
        return total
    }

    private static func size(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey,
                                                             .fileAllocatedSizeKey,
                                                             .fileSizeKey])
        else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }
}
