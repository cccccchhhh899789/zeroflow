import SwiftUI
import AppKit

/// 面板度量：控制器算窗口尺寸、视图排版共用，避免两处漂移
enum ClipboardPanelMetrics {
    static let listWidth: CGFloat = 360
    static let previewWidth: CGFloat = 460
    static let rowHeight: CGFloat = 34
    static let searchHeight: CGFloat = 44
    static let footerHeight: CGFloat = 28
    static let maxRows = 10
    static let cornerRadius: CGFloat = 14
    static let dividerWidth: CGFloat = 1

    /// 展开态总宽。内容永远按这个宽度布局，窗口从 `listWidth` 长到它只是把预览"揭开"（DEV-068）
    static var expandedWidth: CGFloat { listWidth + dividerWidth + previewWidth }

    static func rows(for count: Int) -> Int {
        max(1, min(count, maxRows))
    }

    static func height(for count: Int) -> CGFloat {
        searchHeight + CGFloat(rows(for: count)) * rowHeight + footerHeight + 10
    }
}

/// 剪贴板历史面板的展示模型（仅主线程读写）
final class ClipboardViewModel: ObservableObject {
    @Published var items: [ClipboardItem]
    @Published var query = ""
    @Published var selectedIndex = 0
    @Published var previewItem: ClipboardItem?
    @Published var previewOnLeft = false
    @Published var selectionFromPointer = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter
    }()

    init(items: [ClipboardItem]) {
        self.items = items
    }

    deinit { MemoryProbe.noteDeinit("ClipboardViewModel") }

    var filteredItems: [ClipboardItem] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return items }
        let imageKeyword = L10n.tr("图片").lowercased()
        return items.filter { item in
            if item.sourceAppName.lowercased().contains(keyword) { return true }
            switch item.kind {
            case .image:
                return imageKeyword.contains(keyword)
            case .text:
                return item.text.lowercased().contains(keyword)
            }
        }
    }

    var selectedItem: ClipboardItem? {
        let list = filteredItems
        guard selectedIndex >= 0, selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    static func rowTitle(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text:
            return item.singleLineText
        case .image:
            return "\(L10n.tr("图片")) · \(item.pixelWidth)×\(item.pixelHeight) · \(Self.byteFormatter.string(fromByteCount: Int64(item.byteCount)))"
        }
    }

    static func timeString(for date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func byteString(for item: ClipboardItem) -> String {
        byteFormatter.string(fromByteCount: Int64(item.byteCount))
    }
}

/// 剪贴板历史面板内容：左侧列表（搜索 + 单行记录 + 页脚），右侧仅在展开时出现完整预览
struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardViewModel
    var onSelect: (Int) -> Void
    var onHover: (Int) -> Void
    var onDelete: (ClipboardItem) -> Void
    var onClear: () -> Void

    @FocusState private var searchFocused: Bool
    /// 「清空」二次确认态：点一次进入确认，再点一次才真清；3 秒无操作自动复位
    @State private var confirmingClear = false

    var body: some View {
        // 内容永远按展开态宽度（821）排版，窗口生长只是把它"揭开"：
        // 若让内容跟着窗口宽度重排，主线程一停顿窗口就会横向拉伸旧内容，视觉上整体闪一下（DEV-068）
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 必须用 overlay(alignment:) 把定宽内容钉在宿主左上。
            // 换成 `.frame(maxWidth: .infinity, alignment: .topLeading)` 是不行的：
            // 子视图（821）比宿主（收起态 360）宽时 SwiftUI 会把它**居中**而不是靠左，
            // 左右各裁掉 230pt，列表只剩右半截，要等窗口长到 821 才恢复正常（DEV-068）
            .overlay(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if model.previewOnLeft {
                        previewColumn
                        dividerLine
                    }
                    listColumn
                    if !model.previewOnLeft {
                        dividerLine
                        previewColumn
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .frame(width: ClipboardPanelMetrics.expandedWidth, alignment: .topLeading)
                // 圆角裁剪不放在这里：内容恒定 821 宽，收起态窗口只有 360，
                // 821 上的圆角会跑到窗口外面去，右侧就变成直角。圆角交给宿主 layer（DEV-068）
            }
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: ClipboardPanelMetrics.dividerWidth)
    }

    // MARK: - 列表

    private var listColumn: some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
            if model.filteredItems.isEmpty {
                emptyState
            } else {
                list
            }
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
            footer
        }
        .frame(width: ClipboardPanelMetrics.listWidth)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            TextField(L10n.tr("搜索剪贴板历史"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardPanelMetrics.searchHeight)
        .onAppear {
            // 面板刚成为 key window 时设焦点，避免首帧 TextField 尚未挂载
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // 必须 Lazy：普通 VStack 会把历史里所有行一次性建出来，
                // 每行的缩略图（旧实现是整张解码大 PNG）跟着全部跑一遍（DEV-047）
                // 必须 Lazy：普通 VStack 会把历史里所有行一次性建出来，
                // 每行的缩略图都跟着跑一遍（历史里图片一多就是成百次解码）
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { index, item in
                        ClipboardRow(
                            item: item,
                            selected: index == model.selectedIndex,
                            onSelect: { onSelect(index) },
                            onHover: { onHover(index) },
                            onDelete: { onDelete(item) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onChange(of: model.selectedIndex) {
                // 鼠标 hover 引起的选中变化不滚动，避免列表在光标下跑掉
                guard !model.selectionFromPointer else { return }
                let list = model.filteredItems
                let index = model.selectedIndex
                guard index >= 0, index < list.count else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    // 不传 anchor = 最小滚动：选中项已可见时不动，越出可视区才滚
                    proxy.scrollTo(list[index].id)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(model.query.isEmpty ? L10n.tr("暂无剪贴板历史") : L10n.tr("没有匹配的记录"))
                .font(.system(size: 12.5))
            Text(model.query.isEmpty
                 ? L10n.tr("复制文本或图片后会出现在这里")
                 : L10n.tr("试试其他关键词"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if AccessibilityPermission.isGranted {
                Text(L10n.tr("↑↓ 选择 · ↵ 粘贴 · ⌫ 删除 · esc 关闭"))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                Text(L10n.tr("未授予辅助功能权限：选中仅复制到剪贴板"))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(model.filteredItems.count)")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundColor(.secondary)
            if !model.items.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 10)
                clearButton
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardPanelMetrics.footerHeight)
    }

    /// 清空全部：二次确认（点一次变「确认清空」，再点才执行），3 秒无操作自动复位。
    /// 面板是非激活窗口，弹不了系统 alert，就地二次确认是最轻的做法
    private var clearButton: some View {
        Button {
            if confirmingClear {
                confirmingClear = false
                onClear()
            } else {
                confirmingClear = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    confirmingClear = false
                }
            }
        } label: {
            Text(confirmingClear ? L10n.tr("确认清空") : L10n.tr("清空"))
                .font(.system(size: 10.5, weight: confirmingClear ? .semibold : .regular))
                .foregroundColor(confirmingClear ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(L10n.tr("删除全部剪贴板记录"))
    }

    // MARK: - 预览

    /// 预览列：宽度恒定占位（未展开时是透明空位），只让内容出现/消失。
    /// 占位恒定 = HStack 总宽不变 = 窗口生长期间 SwiftUI 不重排（DEV-068）
    private var previewColumn: some View {
        Group {
            if let item = model.previewItem {
                VStack(alignment: .leading, spacing: 0) {
                    previewHeader(for: item)
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 1)
                    previewBody(for: item)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: ClipboardPanelMetrics.previewWidth)
    }

    private func previewHeader(for item: ClipboardItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.sourceAppName.isEmpty ? L10n.tr("未知来源") : item.sourceAppName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(previewSubtitle(for: item))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(ClipboardViewModel.timeString(for: item.createdAt))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardPanelMetrics.searchHeight)
    }

    private func previewSubtitle(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text:
            let lines = item.text.split(separator: "\n", omittingEmptySubsequences: false).count
            return "\(L10n.tr("文本")) · \(lines) \(L10n.tr("行")) · \(ClipboardViewModel.byteString(for: item))"
        case .image:
            return "\(L10n.tr("图片")) · \(item.pixelWidth)×\(item.pixelHeight) · \(ClipboardViewModel.byteString(for: item))"
        }
    }

    @ViewBuilder private func previewBody(for item: ClipboardItem) -> some View {
        switch item.kind {
        case .text:
            ScrollView(.vertical, showsIndicators: true) {
                Text(item.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        case .image:
            if let image = ClipboardHistoryStore.shared.previewImage(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                Text(L10n.tr("图片已不可用"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// 单行记录：hover 时右侧淡入删除按钮。
/// 按钮宽度恒定占位（只是 opacity 切换），否则鼠标划过时整行文字会被重新分配宽度而抖动。
private struct ClipboardRow: View {
    let item: ClipboardItem
    let selected: Bool
    var onSelect: () -> Void
    var onHover: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 22, height: 22)
                .clipped()
            Text(ClipboardViewModel.rowTitle(for: item))
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(ClipboardViewModel.timeString(for: item.createdAt))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundColor(.secondary)
            deleteButton
        }
        .padding(.horizontal, 8)
        .frame(height: ClipboardPanelMetrics.rowHeight - 2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { onHover() }
        }
        .onTapGesture { onSelect() }
    }

    /// 必须是独立 Button：整行有 onTapGesture，若用 Image + onTapGesture 会被父级手势吞掉，
    /// 点删除会连带触发「粘贴并关闭面板」
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                // hover 必然等于选中（悬停会同步 selectedIndex），所以图标实际总是落在强调色底上，
                // 用 .primary 而不是 .secondary 才够对比度
                .foregroundColor(selected ? Color.primary.opacity(0.85) : Color.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 18, height: 18)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .help(L10n.tr("删除这条记录"))
    }

    @ViewBuilder private var thumbnail: some View {
        switch item.kind {
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image:
            if let image = ClipboardHistoryStore.shared.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
