//
//  CardRepository.swift
//  CamCardClone
//
//  名片数据仓库：封装 SwiftData 的增删改查、多字段模糊搜索与标签筛选。
//  所有方法都在 @MainActor 上执行，ModelContext 不会被跨线程访问。
//
//  持久化红线：
//  - 使用 makePersistentContainer() 创建「磁盘容器」；makeInMemoryContainer() 仅用于测试；
//  - 图片字段只保存 CardImageFileManager 返回的相对路径；
//  - 删除名片时默认同步清理图片目录，撤销删除场景可传 removingImages: false。
//

import Foundation
import SwiftData

// MARK: - 查询选项

/// 多标签筛选语义：OR / AND。
enum TagMatchMode: String, Hashable, Sendable {
    case any
    case all
}

/// 可搜索字段。`.phone` 同时覆盖 mobile / phone / fax。
enum CardSearchField: String, CaseIterable, Hashable, Sendable {
    case name
    case company
    case jobTitle
    case phone
    case email
}

// MARK: - 错误

enum CardRepositoryError: LocalizedError {
    case notFound(UUID)
    case duplicateID(UUID)
    case persistenceFailed(Error)
    case imageCleanupFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "名片不存在或已被删除"
        case .duplicateID:
            return "名片已存在，不能重复插入"
        case .persistenceFailed:
            return "数据保存失败，请重试"
        case .imageCleanupFailed:
            return "名片已删除，但图片文件清理失败"
        }
    }

    /// 供日志 / 诊断使用，不直接展示给用户。
    var underlyingError: Error? {
        switch self {
        case .persistenceFailed(let error), .imageCleanupFailed(let error):
            return error
        case .notFound, .duplicateID:
            return nil
        }
    }
}

// MARK: - 仓库

@MainActor
final class CardRepository {

    // MARK: 依赖

    private let context: ModelContext
    private let imageFileManager: CardImageFileManager?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - context: 必须绑定到持久化 ModelContainer（测试可传内存容器）。
    ///   - imageFileManager: 删除名片时用于清理图片；传 nil 表示由调用方自行管理文件。
    ///   - now: 固定时钟注入点，便于单元测试断言 updatedAt。
    init(
        context: ModelContext,
        imageFileManager: CardImageFileManager? = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.context = context
        self.imageFileManager = imageFileManager
        self.now = now
    }

    /// 使用 ModelContainer 快速创建仓库（内部创建 mainContext）。
    convenience init(
        container: ModelContainer,
        imageFileManager: CardImageFileManager? = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            context: ModelContext(container),
            imageFileManager: imageFileManager,
            now: now
        )
    }

    // MARK: - 容器

    /// 生产环境容器：数据写入 Application Support/default.store，Kill App 后仍在。
    /// 显式关闭 CloudKit，确保零云同步、零网络请求。
    ///
    /// 首次启动时 Application Support 目录可能还不存在，CoreData 直接 fopen
    /// 会报 `fopen failed for data file: errno = 2 (No such file or directory)`
    /// 并导致 persistent store 打不开、后续保存与刷新异常。这里在创建容器前
    /// 显式检查并创建目录（withIntermediateDirectories: true，幂等）。
    static func makePersistentContainer() throws -> ModelContainer {
        do {
            let supportDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            // 目录创建失败时不提前抛出：继续尝试创建 ModelContainer，
            // 让 SwiftData 返回真实错误，由 AppEnvironment 统一降级到内存容器。
        }

        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: BusinessCard.self,
            configurations: configuration
        )
    }

    /// 指定 store 路径的持久化容器（用于迁移 / 测试隔离）。
    static func makePersistentContainer(storeURL: URL) throws -> ModelContainer {
        let parent = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        let schema = Schema([BusinessCard.self])
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }

    /// 内存容器：仅用于 SwiftUI Preview 与单元测试，进程退出即丢失，禁止用于生产。
    static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: BusinessCard.self,
            configurations: configuration
        )
    }

    // MARK: - 增

    /// 插入一张新名片。id 已存在时抛出 `.duplicateID`，避免 SwiftData 唯一约束静默 upsert。
    ///
    /// 注意：
    /// - 调用前必须先把原图 / 校正图写入沙盒，并把 `CardImageFileManager` 返回的相对路径
    ///   赋给 `originalImageFilename` / `processedImageFilename`，再执行本方法；
    /// - 业务校验（姓名/公司至少一个）请在上层调用 `card.validateForSaving()`。
    @discardableResult
    func save(_ card: BusinessCard) throws -> BusinessCard {
        guard try fetch(id: card.id) == nil else {
            throw CardRepositoryError.duplicateID(card.id)
        }

        card.sanitize()
        context.insert(card)

        do {
            try context.save()
        } catch {
            context.rollback()
            throw CardRepositoryError.persistenceFailed(error)
        }
        return card
    }

    // MARK: - 改

    /// 更新名片内容。id 不存在时抛出 `.notFound`。
    /// `createdAt` 保持不变，`updatedAt` 由注入的时钟推进；searchIndex 自动重建。
    func update(_ card: BusinessCard) throws {
        guard let stored = try fetch(id: card.id) else {
            throw CardRepositoryError.notFound(card.id)
        }

        if stored !== card {
            stored.applyContent(from: card)
        }

        stored.sanitize()
        stored.updatedAt = max(now(), stored.createdAt)

        do {
            try context.save()
        } catch {
            context.rollback()
            throw CardRepositoryError.persistenceFailed(error)
        }
    }

    // MARK: - 删

    /// 删除名片及图片。id 不存在时仍会尝试清理图片，保证幂等。
    ///
    /// - Parameter removingImages: 5 秒撤销删除场景传 false，撤销窗口结束再清理文件。
    func delete(id: UUID, removingImages: Bool = true) throws {
        if let card = try fetch(id: id) {
            context.delete(card)
            do {
                try context.save()
            } catch {
                context.rollback()
                throw CardRepositoryError.persistenceFailed(error)
            }
        }

        guard removingImages, let imageFileManager else { return }
        do {
            try imageFileManager.deleteImages(for: id)
        } catch {
            // 数据库删除已提交，这里只报告图片清理失败，避免误导为「删除失败」。
            throw CardRepositoryError.imageCleanupFailed(error)
        }
    }

    /// 便捷重载：删除传入的名片。
    func delete(_ card: BusinessCard, removingImages: Bool = true) throws {
        try delete(id: card.id, removingImages: removingImages)
    }

    /// 清空全部名片（设置页「清空数据」）。数据库与图片目录一并清理。
    func deleteAll(removingImages: Bool = true) throws {
        let cards = try fetchAllCards()
        for card in cards {
            context.delete(card)
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw CardRepositoryError.persistenceFailed(error)
        }

        guard removingImages, let imageFileManager else { return }
        do {
            try imageFileManager.deleteAllImages()
        } catch {
            throw CardRepositoryError.imageCleanupFailed(error)
        }
    }

    // MARK: - 查

    /// 查询全部名片，默认按创建时间倒序。
    func fetchAll(sortedBy sort: CardSort = .createdAtDesc) throws -> [BusinessCard] {
        Self.sorted(try fetchAllCards(), by: sort)
    }

    /// 按标签筛选，默认 OR 语义（规格 §11.1：多选标签为 OR）。
    func fetchAll(
        tags: [String],
        matching tagMode: TagMatchMode = .any,
        sortedBy sort: CardSort = .createdAtDesc
    ) throws -> [BusinessCard] {
        let filtered = filter(try fetchAllCards(), byTags: tags, mode: tagMode)
        return Self.sorted(filtered, by: sort)
    }

    /// 按 id 查询单张名片。
    ///
    /// 这里在内存中过滤而不是使用 `#Predicate`：
    /// SwiftData 的谓词宏会捕获 `ReferenceWritableKeyPath`，在 Strict Concurrency
    /// 下产生 Sendable 警告；名片规模为千级，全量 fetch + first 的耗时可以忽略。
    func fetch(id: UUID) throws -> BusinessCard? {
        try fetchAllCards().first { $0.id == id }
    }

    /// 当前名片数量（设置页统计使用）。
    func count() throws -> Int {
        do {
            return try context.fetchCount(FetchDescriptor<BusinessCard>())
        } catch {
            throw CardRepositoryError.persistenceFailed(error)
        }
    }

    /// 重复检测：手机号完全匹配，或 name + "|" + company 完全匹配。
    func exists(matching key: String) throws -> Bool {
        let folded = BusinessCard.foldedSearchText(key)
        guard !folded.isEmpty else { return false }

        let cards = try fetchAllCards()

        let digits = BusinessCard.digitsOnly(folded)
        let phoneCharacters = "0123456789+-() "
        let looksLikePhone = digits.count >= 7
            && folded.allSatisfy { phoneCharacters.contains($0) }

        if looksLikePhone {
            return cards.contains { card in
                guard let mobile = card.mobile else { return false }
                return BusinessCard.digitsOnly(mobile) == digits
            }
        }

        let parts = folded
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return false
        }

        return cards.contains { card in
            BusinessCard.foldedSearchText(card.name ?? "") == parts[0]
                && BusinessCard.foldedSearchText(card.company ?? "") == parts[1]
        }
    }

    // MARK: - 搜索

    /// 多字段模糊搜索。
    ///
    /// 规则：
    /// - 大小写、变音符号、全半角不敏感；
    /// - 查询按空白/标点切词，多个词之间为 AND（每个词都必须命中）；
    /// - 每个词可在 name / company / jobTitle / phone / email 任一字段命中；
    /// - phone 额外做纯数字匹配，忽略空格、括号、连字符；
    /// - 纯号码查询（≥5 位）直接与 mobile / phone / fax 的数字串比较；
    /// - 默认额外检索 searchIndex（含拼音、标签、备注等），用于 chen / cyz 等输入；
    /// - 排序：完全匹配 > 前缀匹配 > 包含匹配，同级按 updatedAt 倒序。
    ///
    /// - Parameters:
    ///   - query: 空串或纯空白返回全部；纯特殊字符返回空数组，绝不退化为全量。
    ///   - fields: 需要检索的字段集合，默认全部五个。
    ///   - tags: 可选的标签前置筛选。
    ///   - tagMode: 标签 OR / AND。
    func search(
        _ query: String,
        within fields: Set<CardSearchField> = Set(CardSearchField.allCases),
        tags: [String] = [],
        matching tagMode: TagMatchMode = .any
    ) throws -> [BusinessCard] {
        let allCards = try fetchAllCards()
        let candidates = filter(allCards, byTags: tags, mode: tagMode)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // 空查询恢复全部。
        guard !trimmed.isEmpty else {
            return Self.sorted(candidates, by: .createdAtDesc)
        }
        guard !fields.isEmpty else { return [] }

        let parsed = ParsedQuery(query: trimmed)

        // 纯号码查询：一次性比较完整数字串，避免 "+1 202 555 0143" 被空格切碎。
        if parsed.isPhoneQuery {
            guard fields.contains(.phone) else { return [] }

            var ranked: [(card: BusinessCard, score: Int)] = []
            for card in candidates {
                let best = Self.values(for: .phone, in: card)
                    .compactMap { Self.phoneScore(token: parsed.digits, in: $0) }
                    .max() ?? 0
                if best > 0 {
                    ranked.append((card, best))
                }
            }
            return Self.rankedCards(ranked)
        }

        // 纯特殊字符（如 "%"、";"）不产生 token，返回空而非全量。
        guard !parsed.tokens.isEmpty else { return [] }

        let includeSearchIndex = fields == Set(CardSearchField.allCases)
        var ranked: [(card: BusinessCard, score: Int)] = []

        for card in candidates {
            var totalScore = 0
            var matchedAllTokens = true

            for token in parsed.tokens {
                guard let score = Self.tokenScore(
                    token,
                    card: card,
                    fields: fields,
                    includeSearchIndex: includeSearchIndex
                ) else {
                    matchedAllTokens = false
                    break
                }
                totalScore += score
            }

            if matchedAllTokens, totalScore > 0 {
                ranked.append((card, totalScore))
            }
        }

        return Self.rankedCards(ranked)
    }

    // MARK: - 查询内部实现

    private func fetchAllCards() throws -> [BusinessCard] {
        do {
            return try context.fetch(FetchDescriptor<BusinessCard>())
        } catch {
            throw CardRepositoryError.persistenceFailed(error)
        }
    }

    private func filter(
        _ cards: [BusinessCard],
        byTags tags: [String],
        mode: TagMatchMode
    ) -> [BusinessCard] {
        let targetTags = Set(tags.compactMap { normalizedTag($0) })
        guard !targetTags.isEmpty else { return cards }

        return cards.filter { card in
            let cardTags = Set(card.tags.compactMap { normalizedTag($0) })
            switch mode {
            case .any:
                return !cardTags.isDisjoint(with: targetTags)
            case .all:
                return targetTags.isSubset(of: cardTags)
            }
        }
    }

    private func normalizedTag(_ tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return BusinessCard.foldedSearchText(trimmed)
    }

    // MARK: - 搜索内部实现

    private struct ParsedQuery {
        let tokens: [String]
        let digits: String
        let isPhoneQuery: Bool

        init(query: String) {
            let folded = BusinessCard.foldedSearchText(query)

            tokens = folded
                .split { character in
                    character.isWhitespace || character.isPunctuation || character.isSymbol
                }
                .map(String.init)
                .filter { !$0.isEmpty }

            digits = BusinessCard.digitsOnly(folded)

            // 仅由号码字符组成且至少 5 位，才按「纯号码查询」处理。
            let phoneCharacters = "0123456789+-()/. "
            isPhoneQuery = digits.count >= 5
                && !folded.isEmpty
                && folded.allSatisfy { phoneCharacters.contains($0) }
        }
    }

    private static func values(for field: CardSearchField, in card: BusinessCard) -> [String] {
        switch field {
        case .name:
            return [card.name].compactMap { $0 }
        case .company:
            return [card.company].compactMap { $0 }
        case .jobTitle:
            return [card.jobTitle].compactMap { $0 }
        case .phone:
            return [card.mobile, card.phone, card.fax].compactMap { $0 }
        case .email:
            return [card.email].compactMap { $0 }
        }
    }

    private static func tokenScore(
        _ token: String,
        card: BusinessCard,
        fields: Set<CardSearchField>,
        includeSearchIndex: Bool
    ) -> Int? {
        var best = 0

        for field in fields {
            for value in values(for: field, in: card) {
                let folded = BusinessCard.foldedSearchText(value)

                if let score = textScore(token: token, in: folded) {
                    best = max(best, score)
                }
                if field == .phone, let score = phoneScore(token: token, in: value) {
                    best = max(best, score)
                }
            }
        }

        // searchIndex 兜底：覆盖拼音与 searchIndex 中的其他字段。
        // 命中分数固定为 1，确保直接字段匹配始终排在前面。
        if best == 0, includeSearchIndex, card.searchIndex.contains(token) {
            best = 1
        }

        return best > 0 ? best : nil
    }

    private static func textScore(token: String, in value: String) -> Int? {
        guard !token.isEmpty, !value.isEmpty else { return nil }

        if value == token { return 5 }
        if value.hasPrefix(token) { return 4 }
        if value.contains(token) { return 3 }
        return nil
    }

    private static func phoneScore(token: String, in value: String) -> Int? {
        // 只有纯数字 token 才做号码匹配，避免 "abc123" 命中无关号码。
        guard token.allSatisfy({ $0.isNumber }) else { return nil }

        let tokenDigits = BusinessCard.digitsOnly(token)
        guard tokenDigits.count >= 3 else { return nil }

        let valueDigits = BusinessCard.digitsOnly(value)
        guard !valueDigits.isEmpty else { return nil }

        if valueDigits == tokenDigits { return 5 }
        if valueDigits.hasPrefix(tokenDigits) { return 4 }
        if valueDigits.contains(tokenDigits) { return 3 }
        return nil
    }

    private static func rankedCards(
        _ ranked: [(card: BusinessCard, score: Int)]
    ) -> [BusinessCard] {
        ranked
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return isOrderedBefore(lhs.card, rhs.card, by: .updatedAtDesc)
            }
            .map(\.card)
    }

    // MARK: - 排序实现

    private static func sorted(_ cards: [BusinessCard], by sort: CardSort) -> [BusinessCard] {
        cards.sorted { isOrderedBefore($0, $1, by: sort) }
    }

    /// 严格弱序：所有分支都有 id 兜底，保证 sorted 行为稳定。
    private static func isOrderedBefore(
        _ lhs: BusinessCard,
        _ rhs: BusinessCard,
        by sort: CardSort
    ) -> Bool {
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

    /// 空值排在最后；返回 nil 表示两者相等，交给下一级比较。
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
}
