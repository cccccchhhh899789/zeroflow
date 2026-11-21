import Foundation

/// 更新检测：查询 GitHub 最新 Release，与本机 CFBundleShortVersionString 比对。
/// 只回答「有没有新版」，下载与安装交给 UpdateInstaller。
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release {
        let version: String
        let notes: String
        let pageURL: URL
        /// 与当前 CPU 架构匹配的 DMG；无匹配资产时为 nil（降级为打开 Release 页）
        let assetURL: URL?
    }

    enum CheckResult {
        case upToDate(current: String)
        case updateAvailable(Release)
        case failed(reason: String)
    }

    private let repo = "hellolio/zeroflow"
    private let requestTimeout: TimeInterval = 8

    private init() {}

    /// 本机版本号。ZEROFLOW_FAKE_VERSION 优先，便于本地验证三态。
    static var currentVersion: String {
        let fake = ProcessInfo.processInfo.environment["ZEROFLOW_FAKE_VERSION"] ?? ""
        if !fake.isEmpty { return normalize(fake) }
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return normalize(raw)
    }

    /// 手动检查。completion 在主线程回调。
    func check(completion: @escaping (CheckResult) -> Void) {
        Task.detached(priority: .utility) {
            let result = await self.performCheck()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 启动时检查一次：不设定时器也不节流，只有确实有新版才回调。
    func autoCheck(completion: @escaping (Release) -> Void) {
        #if DEBUG
        // 本地 Debug 构建的版本号恒为 pbxproj 里的 1.0，启动检查必然误报；
        // 需要验证时设 ZEROFLOW_UPDATE_AUTOCHECK=1 强制打开。
        if ProcessInfo.processInfo.environment["ZEROFLOW_UPDATE_AUTOCHECK"] != "1" { return }
        #endif
        check { result in
            if case .updateAvailable(let release) = result { completion(release) }
        }
    }

    // MARK: - 网络

    private func performCheck() async -> CheckResult {
        let current = Self.currentVersion
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failed(reason: "bad url")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Zeroflow/\(current)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                ZSLog("UpdateChecker: HTTP \(code)")
                return .failed(reason: "HTTP \(code)")
            }
            guard let payload = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                ZSLog("UpdateChecker: 解析 release JSON 失败")
                return .failed(reason: "decode")
            }

            let latest = Self.normalize(payload.tagName)
            guard Self.isValidVersion(latest) else {
                ZSLog("UpdateChecker: 忽略非语义化 tag \(payload.tagName)")
                return .failed(reason: "invalid tag")
            }

            guard Self.compare(latest, current) == .orderedDescending else {
                return .upToDate(current: current)
            }
            return .updateAvailable(makeRelease(version: latest, payload: payload))
        } catch {
            ZSLog("UpdateChecker: 请求失败 \(error.localizedDescription)")
            return .failed(reason: error.localizedDescription)
        }
    }

    private func makeRelease(version: String, payload: GitHubRelease) -> Release {
        let page = URL(string: payload.htmlURL)
            ?? URL(string: "https://github.com/\(repo)/releases")!
        let dmgAssets = payload.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let matched = dmgAssets.first { $0.name.contains(Self.archToken) }
            ?? dmgAssets.first { $0.name.lowercased().contains("universal") }
        return Release(
            version: version,
            notes: Self.cleanNotes(payload.body ?? ""),
            pageURL: page,
            assetURL: matched.flatMap { URL(string: $0.downloadURL) }
        )
    }

    // MARK: - 版本号

    static func normalize(_ version: String) -> String {
        var s = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// 只接受 x.y / x.y.z 这种纯数字段，过滤 v1.5.11.test 之类。
    static func isValidVersion(_ version: String) -> Bool {
        let parts = normalize(version).split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return false }
        return parts.allSatisfy { part in !part.isEmpty && part.allSatisfy(\.isNumber) }
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = numericParts(lhs)
        let b = numericParts(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericParts(_ version: String) -> [Int] {
        normalize(version).split(separator: ".").map { Int($0) ?? 0 }
    }

    private static var archToken: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Release body 是 Markdown，NSAlert 里只显示纯文本；顺手截断，避免长期持有整段日志。
    private static func cleanNotes(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = line.trimmingCharacters(in: .whitespaces)
            while s.hasPrefix("#") { s.removeFirst() }
            s = s.trimmingCharacters(in: .whitespaces)
            s = s.replacingOccurrences(of: "**", with: "")
            s = s.replacingOccurrences(of: "`", with: "")
            if s.hasPrefix("- ") || s.hasPrefix("* ") { s = "• " + s.dropFirst(2) }
            lines.append(s)
        }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = joined.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        return String(compact.prefix(4000))
    }

    // MARK: - GitHub JSON

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let downloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }
}
