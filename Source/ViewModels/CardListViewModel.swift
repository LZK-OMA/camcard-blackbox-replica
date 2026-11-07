//
//  CardListViewModel.swift
//  CamCardClone
//
//  名片夹 ViewModel：搜索（200ms 防抖）、标签筛选（OR）、排序与空态判定。
//

import Foundation
import Observation

@MainActor
@Observable
final class CardListViewModel {

    // MARK: 输出

    private(set) var cards: [BusinessCard] = []

    /// 列表实际渲染用的纯值快照（视图层绝不直接访问 SwiftData 模型属性）。
    private(set) var rows: [CardRowSnapshot] = []

    var errorMessage: String?

    // MARK: 输入

    var query = ""
    var selectedTags: Set<String> = []
    var onlyTagged = false
    var sort: CardSort = .createdAtDesc

    // MARK: 依赖

    private let store: CardStore
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(store: CardStore) {
        self.store = store
        reload()
    }

    // MARK: - 状态

    var allTags: [String] { store.allTags }
    var totalCount: Int { store.cards.count }
    var hasAnyCards: Bool { !store.cards.isEmpty }
    var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedTags.isEmpty
            || onlyTagged
    }

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var emptyStateKind: EmptyStateKind {
        if hasAnyCards {
            return isFiltering ? .noResults : .none
        }
        return .noCards
    }

    enum EmptyStateKind {
        case none
        case noCards
        case noResults
    }

    // MARK: - 视图值类型（避免 SwiftData 模型进入 SwiftUI 属性图）

    /// 列表行的纯值快照。
    ///
    /// 死锁根因（已用 `sample` 抓到完整调用链）：
    /// SwiftUI 的属性图更新可能在后台渲染线程
    /// （`com.apple.SwiftUI.AsyncRenderer`）读取 `Identifiable.id`。
    /// 如果 `ForEach` 直接使用 SwiftData `@Model`，后台线程读取模型属性会触发
    /// SwiftData 的 `NSManagedObjectContext.performAndWait`（同步等待主队列）；
    /// 此时主线程又在等待 SwiftUI 内部的 `_MovableLock`（该锁正被后台渲染线程持有），
    /// 两者互等 => 整屏无响应、主线程停在 `__psynch_mutexwait`。
    ///
    /// 因此列表只渲染纯值快照：id / 文本 / 标签 / 缩略图路径全部提前在主线程取好。
    struct CardRowSnapshot: Identifiable, Hashable {
        let id: UUID
        let title: String
        let company: String?
        let jobTitle: String?
        let primaryNumber: String?
        let tags: [String]
        let thumbnailPath: String?
    }

    /// 导航路由值：`==` / `hash` 只使用 UUID，绝不访问 SwiftData 属性。
    ///
    /// 返回列表（pop 转场）时 SwiftUI 会重新比较/哈希导航路径里的值；
    /// 如果路径元素是 `BusinessCard`，就会调用 SwiftData 生成的 `hash`/`==`
    /// （内部访问 `id`）并可能发生在后台渲染线程 => 同样触发 performAndWait 死锁。
    struct CardRoute: Hashable {
        let id: UUID
        let card: BusinessCard

        static func == (lhs: CardRoute, rhs: CardRoute) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    // MARK: - 查询

    func reload() {
        do {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

            // 无搜索、无筛选：直接复用 CardStore 的内存快照并排序，
            // 不发起 SwiftData 查询。这是「保存名片后返回列表」的主路径——
            // 避免主线程在扫描流程收尾时同步 fetch，与 CoreData 内部锁互等。
            if trimmedQuery.isEmpty && selectedTags.isEmpty && !onlyTagged {
                cards = Self.sortedCards(store.cards, by: sort)
                rows = cards.map(Self.makeRow)
                errorMessage = nil
                return
            }

            var result = try store.search(
                query,
                tags: Array(selectedTags),
                sortedBy: sort
            )
            if onlyTagged {
                result = result.filter { !$0.tags.isEmpty }
            }
            cards = Self.sortedCards(result, by: sort)
            rows = cards.map(Self.makeRow)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 在主线程把 SwiftData 模型转成纯值快照；视图层只读快照。
    private static func makeRow(_ card: BusinessCard) -> CardRowSnapshot {
        CardRowSnapshot(
            id: card.id,
            title: card.displayTitle,
            company: card.company,
            jobTitle: card.jobTitle,
            primaryNumber: [card.mobile, card.phone]
                .compactMap { $0 }
                .first { !$0.isEmpty },
            tags: card.tags,
            thumbnailPath: card.processedImageFilename ?? card.originalImageFilename
        )
    }

    /// 与 `CardRepository` 完全一致的排序语义（含空值与 id 兜底），
    /// 用于内存快照排序，避免为了排序而重新查询 SwiftData。
    private static func sortedCards(_ cards: [BusinessCard], by sort: CardSort) -> [BusinessCard] {
        cards.sorted { lhs, rhs in
            switch sort {
            case .createdAtDesc:
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
            case .updatedAtDesc:
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
            case .nameAsc:
                if let ordered = compareOptionalText(lhs.name, rhs.name) {
                    return ordered
                }
            case .companyAsc:
                if let ordered = compareOptionalText(lhs.company, rhs.company) {
                    return ordered
                }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// 空值排在最后；返回 nil 表示相等，交给下一级比较。
    private static func compareOptionalText(_ lhs: String?, _ rhs: String?) -> Bool? {
        let left = lhs ?? ""
        let right = rhs ?? ""

        if left.isEmpty != right.isEmpty {
            return !left.isEmpty
        }
        if left.isEmpty && right.isEmpty {
            return nil
        }

        let result = left.localizedStandardCompare(right)
        if result == .orderedSame {
            return nil
        }
        return result == .orderedAscending
    }

    func scheduleReload() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// 把刷新推迟到当前主线程事务之后再执行。
    ///
    /// `reload()` 会同步走一次 SwiftData 查询。如果在 SwiftUI 的
    /// `onAppear` / `onChange`（视图更新周期内）直接调用，就会在
    /// 视图更新过程中重入数据层，容易与 SwiftData/CoreData 的内部锁
    /// 形成死等（表现为整屏点不动、CPU 0%、主线程停在 `__psynch_mutexwait`）。
    /// 因此视图回调统一使用本方法，让查询落在下一个主线程周期。
    @MainActor
    func reloadSoon() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.reload()
        }
    }

    // MARK: - 标签筛选

    func selectAllTags() {
        guard !selectedTags.isEmpty || onlyTagged else { return }
        selectedTags.removeAll()
        onlyTagged = false
        reload()
    }

    func toggleTaggedFilter() {
        onlyTagged.toggle()
        if onlyTagged {
            selectedTags.removeAll()
        }
        reload()
    }

    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
        if onlyTagged {
            onlyTagged = false
        }
        reload()
    }

    func isTagSelected(_ tag: String) -> Bool {
        selectedTags.contains(tag)
    }

    var isAllTagsSelected: Bool {
        selectedTags.isEmpty && !onlyTagged
    }

    // MARK: - 排序

    func selectSort(_ newSort: CardSort) {
        guard sort != newSort else { return }
        sort = newSort
        reload()
    }

    func sortTitle(for sort: CardSort) -> String {
        switch sort {
        case .createdAtDesc: return "最近添加"
        case .updatedAtDesc: return "最近修改"
        case .nameAsc: return "姓名 A–Z"
        case .companyAsc: return "公司 A–Z"
        }
    }

    // MARK: - 交互 / 导航状态（从 CardListView 抽出，便于无头单测）

    /// 列表 → 详情页的值驱动导航路径。
    /// 卡片点击只 append；由 CardListView 的 `.navigationDestination(for:)` 决定目的地。
    var route: [CardRoute] = []

    /// 扫描流程全屏覆盖层是否可见。
    private(set) var isScannerPresented = false
    /// 本次扫描流程是否以「系统相册」作为首屏入口。
    private(set) var startsWithPhotoPicker = false
    /// 每次拉起扫描流程都换一个新的视图身份，保证相机/相册页 @State 从零开始。
    private(set) var scannerSessionID = UUID()
    /// 保存成功后的关闭请求是否已排队，防止重复触发。
    private(set) var isScannerDismissScheduled = false

    /// 卡片点击唯一入口：把选中的名片交给路由。
    /// 返回是否成功写入（路由状态变化即视为成功）。
    @discardableResult
    @MainActor
    func openDetail(_ card: BusinessCard) -> Bool {
        route.append(CardRoute(id: card.id, card: card))
        return route.last?.id == card.id
    }

    /// 列表行点击入口：行里只有纯值快照，这里在主线程按 id 找回模型后入路由。
    @discardableResult
    @MainActor
    func openDetail(cardID: UUID) -> Bool {
        if let card = cards.first(where: { $0.id == cardID })
            ?? store.cards.first(where: { $0.id == cardID }) {
            return openDetail(card)
        }
        return false
    }

    /// 「扫描名片 / 从相册导入」的唯一状态收口。
    ///
    /// - 一次调用对应一次明确的 false → true 状态跃迁；
    /// - 若上一次呈现残留 true（转场被系统丢弃等），先归零、下一主线程周期再拉起，
    ///   避免入口被永久锁死。
    @MainActor
    func presentScanner(startsWithPhotoPicker: Bool) {
        self.startsWithPhotoPicker = startsWithPhotoPicker
        scannerSessionID = UUID()
        isScannerDismissScheduled = false

        if isScannerPresented {
            isScannerPresented = false
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                self?.isScannerPresented = true
            }
        } else {
            isScannerPresented = true
            print("✅ isScannerPresented 已置为 true（@MainActor）")
        }
    }

    /// 保存成功后延迟关闭扫描覆盖层：先等扫描页内部导航栈 pop 完校对页。
    @MainActor
    func scheduleScannerDismissal(delay: Duration = .milliseconds(400)) {
        guard !isScannerDismissScheduled else { return }
        isScannerDismissScheduled = true

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.isScannerPresented = false
            print("🌀 扫描覆盖层已移除（等内部导航 pop 完成后）")
        }
    }

    /// 扫描覆盖层已从视图树移除后的收尾：复位一次性参数，避免影响下一次呈现。
    @MainActor
    func scannerDidDismiss() {
        startsWithPhotoPicker = false
        isScannerDismissScheduled = false
    }

    /// 立即移除扫描覆盖层（相机页「关闭」；此时没有压栈的校对页）。
    @MainActor
    func dismissScanner() {
        isScannerPresented = false
    }

    /// 宿主列表在扫描流程结束后统一刷新挂起的数据变更。
    /// 刷新延后一个主线程周期，避免在扫描覆盖层移除的同一帧里重入数据层。
    @MainActor
    func reloadAfterScannerDismissal() {
        scannerDidDismiss()
        reloadSoon()
    }
}
