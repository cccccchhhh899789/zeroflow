import Foundation

/// 一键更新：流式下载 DMG → 挂载 → 起一个等主进程退出的替换脚本 → 由脚本替换 app 并重启。
/// 任何一步失败都保留 DMG，交给调用方降级为「打开安装包手动拖入」。
final class UpdateInstaller: NSObject {
    static let shared = UpdateInstaller()

    enum InstallError: LocalizedError {
        case downloadFailed(String)
        case notWritable(URL)
        case mountFailed
        case appNotFound
        case prepareFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let reason):
                return L10n.tr("下载安装包失败：%@", arguments: reason)
            case .notWritable:
                return L10n.tr("无法写入应用所在目录")
            case .mountFailed:
                return L10n.tr("无法打开下载的安装包")
            case .appNotFound:
                return L10n.tr("安装包里没有找到 Zeroflow.app")
            case .prepareFailed(let reason):
                return reason
            }
        }
    }

    private var session: URLSession?
    private var progressHandler: ((Double) -> Void)?
    private var completionHandler: ((Result<Void, Error>) -> Void)?
    private var runner: Process?
    private var isInstalling = false

    private override init() { super.init() }

    /// 开始下载并安装。progress 与 completion 都在主线程回调；completion 成功时替换脚本已在等待。
    func install(from remoteURL: URL,
                 progress: @escaping (Double) -> Void,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isInstalling else { return }
        isInstalling = true
        progressHandler = progress
        completionHandler = completion

        guard let dir = Self.stagingDirectory() else {
            finish(.failure(InstallError.downloadFailed("staging")))
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: remoteURL).resume()
        ZSLog("UpdateInstaller: 开始下载 \(remoteURL.lastPathComponent) → \(dir.path)")
    }

    // MARK: - 下载落盘

    private static func stagingDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("com.zeroflow.app/updates", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - 挂载与替换

    private func prepareAndRelaunch(dmg: URL) {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            ZSLog("UpdateInstaller: 目标目录不可写 \(parent.path)")
            DispatchQueue.main.async { self.finish(.failure(InstallError.notWritable(dmg))) }
            return
        }

        let mountPoint = NSTemporaryDirectory() + "zeroflow-mount-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async {
                self.finish(.failure(InstallError.prepareFailed(error.localizedDescription)))
            }
            return
        }

        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mountPoint, dmg.path]
        let sink = Pipe()
        attach.standardOutput = sink
        attach.standardError = sink
        do {
            try attach.run()
            attach.waitUntilExit()
        } catch {
            detach(mountPoint)
            DispatchQueue.main.async { self.finish(.failure(InstallError.mountFailed)) }
            return
        }
        guard attach.terminationStatus == 0 else {
            ZSLog("UpdateInstaller: hdiutil attach 失败 \(attach.terminationStatus)")
            detach(mountPoint)
            DispatchQueue.main.async { self.finish(.failure(InstallError.mountFailed)) }
            return
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint)) ?? []
        guard let appName = contents.first(where: { $0 == "Zeroflow.app" })
                ?? contents.first(where: { $0.hasSuffix(".app") }) else {
            detach(mountPoint)
            DispatchQueue.main.async { self.finish(.failure(InstallError.appNotFound)) }
            return
        }

        let source = mountPoint + "/" + appName
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        # Zeroflow 自动更新：等主进程退出后替换 app bundle，再重启。
        trap '' HUP
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(quote(target.path)).old
        mv \(quote(target.path)) \(quote(target.path)).old || exit 1
        if ! /usr/bin/ditto \(quote(source)) \(quote(target.path)); then
            mv \(quote(target.path)).old \(quote(target.path))
            exit 1
        fi
        rm -rf \(quote(target.path)).old
        /usr/bin/xattr -cr \(quote(target.path))
        /usr/bin/hdiutil detach \(quote(mountPoint)) -force >/dev/null 2>&1
        rm -rf \(quote(mountPoint))
        rm -f \(quote(dmg.path))
        /usr/bin/open \(quote(target.path))
        """

        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zeroflow-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            detach(mountPoint)
            DispatchQueue.main.async {
                self.finish(.failure(InstallError.prepareFailed(error.localizedDescription)))
            }
            return
        }

        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/sh")
        runner.arguments = [scriptURL.path]
        do {
            try runner.run()
        } catch {
            detach(mountPoint)
            DispatchQueue.main.async {
                self.finish(.failure(InstallError.prepareFailed(error.localizedDescription)))
            }
            return
        }
        self.runner = runner

        ZSLog("UpdateInstaller: 替换脚本已启动，主进程准备退出")
        DispatchQueue.main.async { self.finish(.success(())) }
    }

    private func detach(_ mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-force"]
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: mountPoint)
    }

    /// 单引号包裹，路径里若真有单引号按 shell 规则转义。
    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func finish(_ result: Result<Void, Error>) {
        session?.invalidateAndCancel()
        session = nil
        progressHandler = nil
        let handler = completionHandler
        completionHandler = nil
        isInstalling = false
        handler?(result)
    }
}

extension UpdateInstaller: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progressHandler?(value) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let dir = Self.stagingDirectory() else {
            DispatchQueue.main.async { self.finish(.failure(InstallError.downloadFailed("staging"))) }
            return
        }
        let dest = dir.appendingPathComponent("Zeroflow-update.dmg")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            DispatchQueue.main.async {
                self.finish(.failure(InstallError.downloadFailed(error.localizedDescription)))
            }
            return
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        guard size > 1_000_000 else {
            ZSLog("UpdateInstaller: 下载文件过小 \(size) bytes")
            DispatchQueue.main.async { self.finish(.failure(InstallError.downloadFailed("size"))) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { self.prepareAndRelaunch(dmg: dest) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async {
            self.finish(.failure(InstallError.downloadFailed(error.localizedDescription)))
        }
    }
}
