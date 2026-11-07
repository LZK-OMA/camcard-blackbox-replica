//
//  CardStore.swift
//  CamCardClone
//
//  应用级名片数据源（MVVM 的 Model 层入口）。
//
//  职责：
//  - 唯一负责「图片落盘 + SwiftData 写入」的事务边界；
//  - 向所有页面广播数据修订号 `revision`，列表与详情据此刷新；
//  - 暴露标签集合、搜索、删除、备注等高层操作，View 不直接碰 ModelContext。
//

import Foundation
import Observation

// MARK: - 错误

enum CardStoreError: LocalizedError, Equatable {
    case invalidForm(String)
    case duplicateTag(String)
    case tagTooLong
    case notesTooLong
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .invalidForm(let message):
            return message
        case .duplicateTag(let tag):
            return "标签「\(tag)」已存在"
        case .tagTooLong:
            return "单个标签不能超过 \(BusinessCard.maxTagLength) 个字符"
        case .notesTooLong:
            return "备注不能超过 \(BusinessCard.maxNotesLength) 个字符"
        case .persistence(let message):
            return message
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class CardStore {

    // MARK: 依赖

    private let repository: CardRepository
    let imageFileManager: CardImageFileManager

    // MARK: 状态

    /// 按创建时间倒序的全量名片。页面只读，不允许直接增删。
    private(set) var cards: [BusinessCard] = []

    /// 全量标签，按出现次数倒序、同次数按拼音排序。
    private(set) var allTags: [String] = []

    /// 数据修订号。任何写操作成功后自增，列表页监听它刷新。
    private(set) var revision = 0

    var errorMessage: String?

    // MARK: 初始化

    init(
        repository: CardRepository,
        imageFileManager: CardImageFileManager = .shared
    ) {
        self.repository = repository
        self.imageFileManager = imageFileManager
        reload()
    }

    // MARK: - 读

    /// 重新拉取名片并递增 `revision`。
    /// 该方法被 `@MainActor` 的 CardStore 隔离，列表刷新通知严格发生在主线程。
    func reload() {
        do {
            cards = try repository.fetchAll(sortedBy: .createdAtDesc)
            rebuildTags()
            revision += 1
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fetchAll(tags: [String], sortedBy sort: CardSort) throws -> [BusinessCard] {
        try repository.fetchAll(tags: tags, matching: .any, sortedBy: sort)
    }

    func search(
        _ query: String,
        tags: [String],
        sortedBy sort: CardSort
    ) throws -> [BusinessCard] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return try fetchAll(tags: tags, sortedBy: sort)
        }
        return try repository.search(trimmed, tags: tags, matching: .any)
    }

    func count() -> Int {
        cards.count
    }

    // MARK: - 写：扫描结果

    /// 把校对完成的草稿落盘。图片先写文件、再写数据库，任一步失败都会清理已写图片。
    ///
    /// 线程模型：
    /// - `createCard` 本身由 `@MainActor` 的 `CardStore` 隔离，SwiftData 写入、
    ///   `reload()` 与 `revision` 自增全部发生在主线程，SwiftUI 列表因此安全刷新；
    /// - 图片编码 / 磁盘写入通过 `CardImageFileManager` 的 async API 在后台队列执行，
    ///   主线程在 `await` 期间保持可交互，不会出现保存后 UI 卡死；
    /// - 全链路没有 `wait()` / semaphore 之类的同步等待，不存在主线程自锁。
    @discardableResult
    func createCard(
        from draft: ScanDraft,
        values: CardFormValues
    ) async throws -> BusinessCard {
        if let error = values.validationError {
            throw CardStoreError.invalidForm(error)
        }

        let cardID = UUID()

        do {
            // 后台队列：目录创建 + UIImage 编码 + 原子写盘。
            let originalPath = try await imageFileManager.saveOriginalAsync(
                draft.originalImage,
                cardID: cardID
            )

            var processedPath: String?
            if let processed = draft.processedImage,
               draft.hasDistinctProcessedImage {
                processedPath = try await imageFileManager.saveProcessedAsync(
                    processed,
                    cardID: cardID
                )
            }

            // await 结束后回到 @MainActor，以下操作严格在主线程执行。
            let card = BusinessCard(
                id: cardID,
                originalImageFilename: originalPath,
                processedImageFilename: processedPath,
                createdAt: Date(),
                source: draft.source
            )
            values.apply(to: card)
            try card.validateForSaving()
            try repository.save(card)

            // 保存成功后**不再**做一次同步 SwiftData 查询（fetch）：
            // 主线程上每一次 fetch 都要参与 CoreData 内部锁竞争，是「保存后整屏
            // 点不动、主线程停在 __psynch_mutexwait」的高发点。
            // 这里直接把新名片并入内存快照并递增 revision，UI 拿到同样的结果。
            cards.insert(card, at: 0)   // cards 按 createdAtDesc 维护，新名片最新
            rebuildTags()
            revision += 1
            errorMessage = nil
            return card
        } catch {
            // 无论失败发生在编码、写盘还是数据库阶段，都清理该 cardID 的目录。
            // deleteImages 对不存在的目录是幂等的，且清理本身也放到后台队列。
            try? await imageFileManager.deleteImagesAsync(for: cardID)
            throw Self.storeError(from: error)
        }
    }

    // MARK: - 写：字段编辑

    func updateCard(_ card: BusinessCard, with values: CardFormValues) throws {
        if let error = values.validationError {
            throw CardStoreError.invalidForm(error)
        }

        values.apply(to: card)
        do {
            try card.validateForSaving()
            try repository.update(card)
            reload()
        } catch {
            throw Self.storeError(from: error)
        }
    }

    // MARK: - 写：标签

    func addTag(_ rawTag: String, to card: BusinessCard) throws {
        let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else {
            throw CardStoreError.invalidForm("标签不能为空")
        }
        guard tag.count <= BusinessCard.maxTagLength else {
            throw CardStoreError.tagTooLong
        }

        let key = BusinessCard.foldedSearchText(tag)
        if card.tags.contains(where: { BusinessCard.foldedSearchText($0) == key }) {
            throw CardStoreError.duplicateTag(tag)
        }

        card.tags.append(tag)
        do {
            try repository.update(card)
            reload()
        } catch {
            throw Self.storeError(from: error)
        }
    }

    func removeTag(_ tag: String, from card: BusinessCard) throws {
        card.tags.removeAll {
            BusinessCard.foldedSearchText($0) == BusinessCard.foldedSearchText(tag)
        }
        do {
            try repository.update(card)
            reload()
        } catch {
            throw Self.storeError(from: error)
        }
    }

    // MARK: - 写：备注

    func updateNotes(_ notes: String, for card: BusinessCard) throws {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= BusinessCard.maxNotesLength else {
            throw CardStoreError.notesTooLong
        }

        card.notes = trimmed.isEmpty ? nil : trimmed
        do {
            try repository.update(card)
            reload()
        } catch {
            throw Self.storeError(from: error)
        }
    }

    // MARK: - 写：删除

    func delete(_ card: BusinessCard) throws {
        do {
            try repository.delete(card)
            reload()
        } catch {
            // 数据库删除成功后，仅图片清理失败不应让详情页误以为「未删除」。
            reload()
            if let repositoryError = error as? CardRepositoryError {
                switch repositoryError {
                case .imageCleanupFailed:
                    return
                default:
                    break
                }
            }
            throw Self.storeError(from: error)
        }
    }

    // MARK: - 重复检测

    /// 保存前的软性重复检测：手机号完全相同，或姓名 + 公司完全相同。
    /// 编辑已有名片时不应调用（会命中自己）。
    func hasPotentialDuplicate(for values: CardFormValues) -> Bool {
        if let mobile = values.trimmedValue(for: .mobile),
           (try? repository.exists(matching: mobile)) == true {
            return true
        }

        if let name = values.trimmedValue(for: .name),
           let company = values.trimmedValue(for: .company),
           (try? repository.exists(matching: "\(name)|\(company)")) == true {
            return true
        }

        return false
    }

    // MARK: - 私有

    private func rebuildTags() {
        var counts: [String: Int] = [:]
        for card in cards {
            for tag in card.tags {
                counts[tag, default: 0] += 1
            }
        }

        allTags = counts.keys.sorted { lhs, rhs in
            let left = counts[lhs, default: 0]
            let right = counts[rhs, default: 0]
            if left != right {
                return left > right
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func storeError(from error: Error) -> Error {
        if let error = error as? CardStoreError {
            return error
        }
        if let error = error as? BusinessCard.ValidationError {
            return CardStoreError.invalidForm(error.localizedDescription)
        }
        return CardStoreError.persistence(error.localizedDescription)
    }
}
