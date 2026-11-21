import SwiftUI

/// 更新详情窗口：正文放进 ScrollView，Release 说明再长也不会撑破窗口。
struct UpdateWindowView: View {
    let release: UpdateChecker.Release
    let onInstall: () -> Void
    let onOpenPage: () -> Void
    let onCancel: () -> Void

    private static let appIcon = AppIconCache.ownIcon(pointSize: 28)

    var body: some View {
        // GeometryReader 把 VStack 钉成窗口尺寸，中间 ScrollView 吃剩余高度
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ScrollView(.vertical) {
                    Text(release.notes.isEmpty ? L10n.tr("暂无更新说明。") : release.notes)
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
                Divider()
                footer
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(width: 460)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if let icon = Self.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("发现新版本 %@", arguments: release.version))
                    .font(.system(size: 15, weight: .semibold))
                Text(L10n.tr("当前版本 %@", arguments: UpdateChecker.currentVersion))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .layoutPriority(1)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(L10n.tr("打开下载页"), action: onOpenPage)
                .buttonStyle(.link)
            Spacer(minLength: 0)
            Button(L10n.tr("稍后"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(L10n.tr("立即更新"), action: onInstall)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .layoutPriority(1)
    }
}
