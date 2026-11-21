import Foundation

/// 读取访达扩展在系统里的启用状态（只读）。
///
/// 设计前提：扩展只当「右键菜单注入器」用——appex 塞在 `Contents/PlugIns/`，安装时系统
/// 登记一次，之后 Finder 需要菜单时由 pkd 自己拉起，主 app **不碰 election、不数进程、
/// 不管起停**（iTerm2 / Tower / Fork 同款模型）。这里只查一次 pluginkit 的选举结果用于
/// 设置页显示，不写状态、不拉起实例。
///
/// 为什么不用 `FIFinderSyncController.isExtensionEnabled`：那个 API 要和 pkd 建 client
/// 连接，可能连带拉起一个 app 侧扩展实例（DEV-091 的观察），正是要避免的副作用；
/// 也正因如此主 app 不再链接 FinderSync.framework。
enum FinderSyncElection {
    static let pluginID = "com.zeroflow.app.finderSync"

    enum State {
        case enabled
        case disabled
        /// 查询失败（pluginkit 被拒/输出异常）。**不等于未启用**，UI 不能当成「没开」报警。
        case unknown

        var label: String {
            switch self {
            case .enabled: return "enabled"
            case .disabled: return "disabled"
            case .unknown: return "unknown"
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.zeroflow.app.finderSyncElection")

    /// 后台查询，回调回主线程。
    static func query(completion: @escaping (State) -> Void) {
        queue.async {
            let state = runQuery()
            ZSLog("FinderSyncElection: state=\(state.label)")
            DispatchQueue.main.async { completion(state) }
        }
    }

    private static func runQuery() -> State {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", pluginID]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            ZSLog("FinderSyncElection: 启动 pluginkit 失败 \(error)")
            return .unknown
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            ZSLog("FinderSyncElection: pluginkit 查询失败 status=\(process.terminationStatus)")
            return .unknown
        }
        // 输出形如 "+    com.zeroflow.app.finderSync(1.0)"（启用）/ "-    …"（停用）
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(pluginID) else { continue }
            if trimmed.hasPrefix("+") { return .enabled }
            if trimmed.hasPrefix("-") { return .disabled }
        }
        ZSLog("FinderSyncElection: pluginkit 输出无该插件记录")
        return .unknown
    }
}
