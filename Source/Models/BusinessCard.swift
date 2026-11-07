//
//  BusinessCard.swift
//  CamCardClone
//
//  SwiftData 持久化实体：名片。
//  设计约束：
//  1. 图片只保存「相对 Documents/Cards/ 的路径」，绝不以二进制 Blob 形式入库；
//  2. tags / notes 为普通持久化属性，随 ModelContainer 落盘，冷启动可恢复；
//  3. searchIndex 为派生字段，每次 insert/update 前由 sanitize() 重建。
//

import Foundation
import SwiftData

// MARK: - 枚举

/// 名片来源。持久化时保存 rawValue，避免 SwiftData 对枚举的兼容性问题。
enum CardSource: String, Codable, CaseIterable, Sendable {
    case camera
    case photoLibrary
    case file
    case manual
}

/// 名片列表排序方式。
enum CardSort: String, CaseIterable, Hashable, Sendable {
    case createdAtDesc
    case nameAsc
    case companyAsc
    case updatedAtDesc
}

// MARK: - 实体

/// 名片实体。
///
/// `originalImageFilename` / `processedImageFilename` 只保存相对路径，
/// 例如 `"6F6F.../original.heic"`，其基准目录是 `Documents/Cards/`。
/// App 沙盒根目录在重装、系统迁移后可能变化，因此禁止保存绝对路径。
@Model
final class BusinessCard {

    // MARK: 标识

    @Attribute(.unique) var id: UUID

    // MARK: 结构化字段

    var name: String?
    var company: String?
    var jobTitle: String?
    var mobile: String?
    var phone: String?

    /// 规格扩展字段：传真。与 phone 分开存储，导出 vCard 时映射为 WORK,FAX。
    var fax: String?

    var email: String?
    var website: String?
    var address: String?

    /// 标签：不重复、保持插入顺序，单个标签长度见 `maxTagLength`。
    var tags: [String]

    var notes: String?

    // MARK: 图片（只存相对路径，不存 Blob）

    /// 原图相对路径，必填。由 `CardImageFileManager.saveOriginal` 返回。
    var originalImageFilename: String

    /// 校正图相对路径。检测失败时可以为 nil，由 UI 回退展示原图。
    var processedImageFilename: String?

    // MARK: 审计与检索

    var createdAt: Date
    var updatedAt: Date

    /// 来源 rawValue，读取时通过 `source` 计算属性安全转换。
    var sourceRaw: String

    /// 派生检索串，由 `rebuildSearchIndex()` 重建，不直接由 UI 写入。
    var searchIndex: String

    // MARK: - 常量

    static let maxTagLength = 20
    static let maxNotesLength = 2000
    private static let searchSeparator = "\u{1F}"

    // MARK: - 初始化

    init(
        id: UUID = UUID(),
        name: String? = nil,
        company: String? = nil,
        jobTitle: String? = nil,
        mobile: String? = nil,
        phone: String? = nil,
        fax: String? = nil,
        email: String? = nil,
        website: String? = nil,
        address: String? = nil,
        tags: [String] = [],
        notes: String? = nil,
        originalImageFilename: String,
        processedImageFilename: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        source: CardSource = .manual
    ) {
        self.id = id
        self.name = name
        self.company = company
        self.jobTitle = jobTitle
        self.mobile = mobile
        self.phone = phone
        self.fax = fax
        self.email = email
        self.website = website
        self.address = address
        self.tags = tags
        self.notes = notes
        self.originalImageFilename = originalImageFilename
        self.processedImageFilename = processedImageFilename
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.sourceRaw = source.rawValue
        self.searchIndex = " "

        sanitize()
    }

    // MARK: - 计算属性

    /// 安全读取来源；未知 rawValue 回退到 `.manual`，不崩溃。
    var source: CardSource {
        get { CardSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    /// 规格中的命名兼容别名（值为相对路径，而非绝对路径）。
    var originalImagePath: String {
        get { originalImageFilename }
        set { originalImageFilename = newValue }
    }

    /// 规格中的命名兼容别名（值为相对路径，而非绝对路径）。
    var processedImagePath: String? {
        get { processedImageFilename }
        set { processedImageFilename = newValue }
    }

    /// 用于 UI 的展示名：优先姓名，其次公司，最后占位。
    var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if let company, !company.isEmpty { return company }
        return "未命名名片"
    }

    // MARK: - 数据清洗

    /// 写入数据库前调用：空串转 nil、标签去重、修正 URL/邮箱、保证时间不变量。
    /// 此方法同时重建 searchIndex，因此持久层不需要再单独调用。
    func sanitize() {
        name = Self.cleaned(name)
        company = Self.cleaned(company)
        jobTitle = Self.cleaned(jobTitle)
        mobile = Self.cleaned(mobile)
        phone = Self.cleaned(phone)
        fax = Self.cleaned(fax)
        email = Self.cleaned(email)?.lowercased()
        website = Self.normalizedWebsite(website)
        address = Self.cleaned(address)
        notes = Self.cleaned(notes)
        tags = Self.normalizedTags(tags)

        originalImageFilename = originalImageFilename
            .trimmingCharacters(in: .whitespacesAndNewlines)
        processedImageFilename = Self.cleaned(processedImageFilename)

        // 未知来源回退为 manual，保证 source 始终是合法枚举。
        sourceRaw = source.rawValue

        // 不变量：createdAt <= updatedAt。
        if updatedAt < createdAt {
            updatedAt = createdAt
        }

        rebuildSearchIndex()
    }

    /// 保存前校验（由 UseCase / UI 在调用 repository.save 前执行）。
    /// Repository 保持存储层职责，不替业务层决定「姓名或公司至少一个非空」。
    func validateForSaving() throws {
        guard name != nil || company != nil else {
            throw ValidationError.missingNameAndCompany
        }
        guard !originalImageFilename.isEmpty else {
            throw ValidationError.missingOriginalImage
        }
        if let notes, notes.count > Self.maxNotesLength {
            throw ValidationError.notesTooLong
        }
        if let tag = tags.first(where: { $0.count > Self.maxTagLength }) {
            throw ValidationError.tagTooLong(tag)
        }
    }

    /// 从另一张名片复制业务内容（不复制 id / createdAt，避免破坏审计字段）。
    /// 用于「编辑副本 → 保存」或 Mock 数据幂等覆盖。
    func applyContent(from other: BusinessCard) {
        guard other !== self else { return }

        name = other.name
        company = other.company
        jobTitle = other.jobTitle
        mobile = other.mobile
        phone = other.phone
        fax = other.fax
        email = other.email
        website = other.website
        address = other.address
        tags = other.tags
        notes = other.notes
        originalImageFilename = other.originalImageFilename
        processedImageFilename = other.processedImageFilename
        sourceRaw = other.sourceRaw

        sanitize()
    }

    // MARK: - 检索索引

    /// 重建派生检索串。索引包含原文、拼音全拼、拼音首字母、纯数字号码、标签与备注。
    /// 字段之间使用 U+001F 分隔，避免跨字段拼接造成误命中。
    func rebuildSearchIndex() {
        var components: [String] = []

        func append(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            let folded = Self.foldedSearchText(value)
            if !folded.isEmpty {
                components.append(folded)
            }
        }

        append(name)
        append(company)
        append(jobTitle)
        append(mobile)
        append(phone)
        append(fax)
        append(email)
        append(website)
        append(address)

        // 号码额外保存纯数字形式，便于忽略空格、括号、连字符后检索。
        for value in [mobile, phone, fax].compactMap({ $0 }) {
            let digits = Self.digitsOnly(value)
            if !digits.isEmpty {
                components.append(digits)
            }
        }

        if !tags.isEmpty {
            append(tags.joined(separator: " "))
        }
        append(notes)

        // 中文姓名 / 公司 / 职位补充拼音，支持 chen / cyz 等输入。
        for value in [name, company, jobTitle].compactMap({ $0 }) {
            components.append(contentsOf: Self.pinyinVariants(for: value))
        }

        let index = components.joined(separator: Self.searchSeparator)
        // 规格要求：无内容时也必须是非空串。
        searchIndex = index.isEmpty ? " " : index
    }

    // MARK: - 搜索文本工具

    /// 大小写 / 变音符号 / 全半角不敏感的折叠文本。
    static func foldedSearchText(_ text: String) -> String {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "zh_Hans_CN")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 仅保留数字字符，用于电话号码的格式化无关匹配。
    static func digitsOnly(_ text: String) -> String {
        String(text.filter { $0.isNumber })
    }

    // MARK: - 私有清洗方法

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedWebsite(_ value: String?) -> String? {
        guard var text = cleaned(value)?.lowercased() else { return nil }

        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
            text = "https://" + text
        }
        while text.hasSuffix("/"), text.count > "https://".count {
            text.removeLast()
        }
        return text
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for tag in tags {
            guard let cleaned = cleaned(tag) else { continue }
            let key = foldedSearchText(cleaned)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(cleaned)
        }
        return result
    }

    private static func pinyinVariants(for text: String) -> [String] {
        guard containsCJK(text) else { return [] }

        let latin = text
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? ""
        let folded = foldedSearchText(latin)
        guard !folded.isEmpty else { return [] }

        // 去掉括号等标点，避免首字母被标点污染。
        let letters = folded.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        let syllables = letters.split(whereSeparator: { $0.isWhitespace })
        let compact = letters.replacingOccurrences(of: " ", with: "")
        let initials = syllables.compactMap { $0.first }.map(String.init).joined()

        return [folded, compact, initials].filter { !$0.isEmpty }
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}

// MARK: - 校验错误

extension BusinessCard {

    enum ValidationError: LocalizedError, Equatable {
        case missingNameAndCompany
        case missingOriginalImage
        case notesTooLong
        case tagTooLong(String)

        var errorDescription: String? {
            switch self {
            case .missingNameAndCompany:
                return "请至少填写姓名或公司"
            case .missingOriginalImage:
                return "缺少原图路径，无法保存名片"
            case .notesTooLong:
                return "备注不能超过 \(BusinessCard.maxNotesLength) 个字符"
            case .tagTooLong(let tag):
                return "标签「\(tag)」不能超过 \(BusinessCard.maxTagLength) 个字符"
            }
        }
    }
}
