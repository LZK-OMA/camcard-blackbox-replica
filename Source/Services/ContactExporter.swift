//
//  ContactExporter.swift
//  CamCardClone
//
//  名片导出：
//  - 生成标准 vCard 3.0 文本，并按 RFC 2426 做 75 字节折行；
//  - 写入临时目录，供系统分享面板使用；
//  - 可选写入系统通讯录（Contacts 框架，需要 NSContactsUsageDescription）。
//
//  字段映射遵循 spec §7.8：
//  FN/N、ORG、TITLE、TEL;TYPE=CELL、TEL;TYPE=WORK,VOICE、
//  TEL;TYPE=WORK,FAX、EMAIL;TYPE=INTERNET、URL、
//  ADR;TYPE=WORK、NOTE、CATEGORIES、REV。
//

import Contacts
import Foundation

// MARK: - 错误

enum ContactExporterError: LocalizedError {
    case contactsPermissionDenied
    case contactsSaveFailed(Error)
    case vCardWriteFailed(Error)
    case emptyCard

    var errorDescription: String? {
        switch self {
        case .contactsPermissionDenied:
            return "没有通讯录写入权限，请前往「设置」允许访问通讯录"
        case .contactsSaveFailed:
            return "写入通讯录失败，请重试"
        case .vCardWriteFailed:
            return "vCard 文件生成失败，请重试"
        case .emptyCard:
            return "名片内容为空，无法导出"
        }
    }

    var underlyingError: Error? {
        switch self {
        case .contactsSaveFailed(let error), .vCardWriteFailed(let error):
            return error
        case .contactsPermissionDenied, .emptyCard:
            return nil
        }
    }
}

// MARK: - 导出器

@MainActor
final class ContactExporter {

    private let fileManager: FileManager
    private let exportsDirectoryOverride: URL?

    init(
        fileManager: FileManager = .default,
        exportsDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.exportsDirectoryOverride = exportsDirectory
    }

    // MARK: - vCard 文本

    func vCard(for card: BusinessCard) -> String {
        [
            "BEGIN:VCARD",
            "VERSION:3.0",
            body(for: card),
            "END:VCARD"
        ]
        .flatMap { $0.components(separatedBy: "\n") }
        .map { fold($0) }
        .joined(separator: "\r\n") + "\r\n"
    }

    func vCard(for cards: [BusinessCard]) -> String {
        cards
            .map { vCard(for: $0) }
            .joined(separator: "\r\n")
    }

    // MARK: - 临时文件

    @discardableResult
    func makeVCardFile(for card: BusinessCard) throws -> URL {
        let directory = try ensureExportsDirectory()
        let stamp = Self.timestampFormatter.string(from: Date())
        let title = sanitizedFileComponent(card.displayTitle)
        let filename = "CamCard_\(title)_\(stamp).vcf"
        let url = directory.appendingPathComponent(filename, isDirectory: false)

        return try write(vCard(for: card), to: url)
    }

    @discardableResult
    func makeVCardFile(for cards: [BusinessCard]) throws -> URL {
        guard !cards.isEmpty else {
            throw ContactExporterError.emptyCard
        }

        let directory = try ensureExportsDirectory()
        let stamp = Self.timestampFormatter.string(from: Date())
        let url = directory.appendingPathComponent(
            "CamCards_\(stamp).vcf",
            isDirectory: false
        )

        return try write(vCard(for: cards), to: url)
    }

    /// 分享完成后调用，清理 tmp/Exports 下的临时文件。
    func cleanupTemporaryFiles() {
        let directory = exportsDirectory
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - 写入系统通讯录

    func saveToContacts(_ card: BusinessCard) async throws {
        let store = CNContactStore()
        try await ensureContactsAccess(store)

        let name = splitName(card.name)
        let contact = CNMutableContact()

        contact.familyName = name.family
        contact.givenName = name.given
        contact.organizationName = card.company ?? ""
        contact.jobTitle = card.jobTitle ?? ""

        contact.phoneNumbers = phoneValues(card.mobile).map { value in
            CNLabeledValue(
                label: CNLabelPhoneNumberMobile,
                value: CNPhoneNumber(stringValue: value)
            )
        } + phoneValues(card.phone).map { value in
            CNLabeledValue(
                label: CNLabelPhoneNumberMain,
                value: CNPhoneNumber(stringValue: value)
            )
        } + phoneValues(card.fax).map { value in
            CNLabeledValue(
                label: CNLabelPhoneNumberWorkFax,
                value: CNPhoneNumber(stringValue: value)
            )
        }

        contact.emailAddresses = splitValues(card.email).map { value in
            CNLabeledValue(label: CNLabelWork, value: value as NSString)
        }

        contact.urlAddresses = splitValues(card.website).map { value in
            CNLabeledValue(label: CNLabelURLAddressHomePage, value: value as NSString)
        }

        if let address = card.address, !address.isEmpty {
            let parts = addressComponents(address)
            let postal = CNMutablePostalAddress()
            postal.street = parts[2]
            postal.city = parts[3]
            postal.state = parts[4]
            postal.postalCode = parts[5]
            postal.country = parts[6]
            contact.postalAddresses = [
                CNLabeledValue(label: CNLabelWork, value: postal as CNPostalAddress)
            ]
        }

        // 注意：vCard 的 NOTE 可以自由写入；系统通讯录的 note 字段需要额外授权，
        // 未申请 com.apple.developer.contacts.notes 权限时写入会失败，因此这里不写。

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)

        do {
            try store.execute(request)
        } catch {
            throw ContactExporterError.contactsSaveFailed(error)
        }
    }

    // MARK: - vCard body

    private func body(for card: BusinessCard) -> String {
        var lines: [String] = []

        let name = splitName(card.name)
        let displayName = card.name ?? card.company ?? "未命名名片"

        lines.append("N:\(escape(name.family));\(escape(name.given));;;")
        lines.append("FN:\(escape(displayName))")

        if let company = card.company, !company.isEmpty {
            lines.append("ORG:\(escape(company))")
        }
        if let jobTitle = card.jobTitle, !jobTitle.isEmpty {
            lines.append("TITLE:\(escape(jobTitle))")
        }

        for number in splitValues(card.mobile) {
            lines.append("TEL;TYPE=CELL:\(escape(number))")
        }
        for number in splitValues(card.phone) {
            lines.append("TEL;TYPE=WORK,VOICE:\(escape(number))")
        }
        for number in splitValues(card.fax) {
            lines.append("TEL;TYPE=WORK,FAX:\(escape(number))")
        }

        for email in splitValues(card.email) {
            lines.append("EMAIL;TYPE=INTERNET:\(escape(email))")
        }
        for website in splitValues(card.website) {
            lines.append("URL:\(escape(website))")
        }

        if let address = card.address, !address.isEmpty {
            let parts = addressComponents(address)
            lines.append("ADR;TYPE=WORK:" + parts.map(escape).joined(separator: ";"))
        }

        if let notes = card.notes, !notes.isEmpty {
            lines.append("NOTE:\(escape(notes))")
        }
        if !card.tags.isEmpty {
            lines.append(
                "CATEGORIES:" + card.tags.map(escape).joined(separator: ",")
            )
        }

        lines.append("UID:\(card.id.uuidString)")
        lines.append("REV:\(Self.iso8601.string(from: card.createdAt))")

        return lines.joined(separator: "\n")
    }

    // MARK: - 文本工具

    /// vCard 值转义：反斜杠、换行、分号、逗号。
    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    /// RFC 2426：每行最多 75 字节，续行以一个空格开头。
    /// 以 Character 为单位折叠，避免把一个 UTF-8 多字节字符截断。
    private func fold(_ line: String, limit: Int = 75) -> String {
        guard line.utf8.count > limit else { return line }

        var result = ""
        var byteCount = 0
        for character in line {
            let piece = String(character)
            let pieceBytes = piece.utf8.count
            if byteCount + pieceBytes > limit {
                result += "\r\n "
                byteCount = 1
            }
            result += piece
            byteCount += pieceBytes
        }
        return result
    }

    private func splitValues(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 姓名拆分

    private struct NameParts {
        let family: String
        let given: String
    }

    /// 中文按「姓;名」拆分，英文按「最后一段=姓，其余=名」拆分。
    private func splitName(_ raw: String?) -> NameParts {
        guard let raw else { return NameParts(family: "", given: "") }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return NameParts(family: "", given: "") }

        let cjkCharacters = Array(value.filter(Self.isCJK))
        if !cjkCharacters.isEmpty {
            let compoundSurnames: Set<String> = [
                "欧阳", "司马", "上官", "诸葛", "东方", "皇甫", "尉迟", "公孙",
                "慕容", "司徒", "令狐", "夏侯", "轩辕", "长孙", "宇文", "独孤",
                "南宫", "西门", "端木", "呼延"
            ]

            var familyLength = 1
            if cjkCharacters.count >= 3 {
                let prefix = String(cjkCharacters.prefix(2))
                if compoundSurnames.contains(prefix) {
                    familyLength = 2
                }
            }

            let family = String(cjkCharacters.prefix(familyLength))
            let given = String(cjkCharacters.dropFirst(familyLength))
            return NameParts(family: family, given: given)
        }

        let tokens = value
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }

        guard tokens.count >= 2 else {
            return NameParts(family: "", given: value)
        }

        let family = tokens.last ?? ""
        let given = tokens.dropLast().joined(separator: " ")
        return NameParts(family: family, given: given)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) ||
                (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    // MARK: - 地址拆分

    /// 返回 vCard ADR 的 7 段：PO Box、Extended、Street、Locality、Region、Postal、Country。
    /// 无法可靠结构化时把完整地址放进 Street，绝不臆造缺失部分。
    private func addressComponents(_ raw: String) -> [String] {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            return Array(repeating: "", count: 7)
        }

        if nameContainsCJK(address) {
            return chineseAddressComponents(address)
        }
        return latinAddressComponents(address)
    }

    private func chineseAddressComponents(_ address: String) -> [String] {
        var remainder = address
        var province = ""
        var city = ""
        var district = ""
        var postal = ""

        if let match = firstMatch(
            #"^(.+?(?:省|自治区))"#,
            in: remainder
        ) {
            province = match
            remainder = String(remainder.dropFirst(match.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let match = firstMatch(
            #"^(北京市|上海市|天津市|重庆市)"#,
            in: remainder
        ) {
            province = match
            city = match
            remainder = String(remainder.dropFirst(match.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if city.isEmpty,
           let match = firstMatch(#"^(.+?(?:市|自治州|地区|盟))"#, in: remainder) {
            city = match
            remainder = String(remainder.dropFirst(match.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let match = firstMatch(#"^(.+?(?:区|县|旗))"#, in: remainder) {
            district = match
            remainder = String(remainder.dropFirst(match.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let match = firstMatch(#"\b\d{6}\b"#, in: remainder) {
            postal = match
            remainder = remainder.replacingOccurrences(of: match, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let street = district.isEmpty
            ? remainder
            : [district, remainder].filter { !$0.isEmpty }.joined(separator: " ")

        return [
            "",
            "",
            street,
            city,
            province,
            postal,
            ""
        ]
    }

    private func latinAddressComponents(_ address: String) -> [String] {
        let parts = address
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count >= 2 else {
            return ["", "", address, "", "", "", ""]
        }

        var country = ""
        var region = ""
        var postal = ""
        var city = ""
        var streetParts = parts

        if parts.count >= 3 {
            country = parts[parts.count - 1]
            let regionAndPostal = parts[parts.count - 2]
            if let postalMatch = firstMatch(
                #"\b\d{5}(?:-\d{4})?\b"#,
                in: regionAndPostal
            ) {
                postal = postalMatch
                region = regionAndPostal
                    .replacingOccurrences(of: postalMatch, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                region = regionAndPostal
            }
            city = parts[parts.count - 3]
            streetParts = Array(parts.prefix(parts.count - 3))
        } else {
            streetParts = Array(parts.prefix(1))
            region = parts.last ?? ""
        }

        let street = streetParts.joined(separator: ", ")
        return [
            "",
            "",
            street,
            city,
            region,
            postal,
            country
        ]
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.range.location != NSNotFound,
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private func nameContainsCJK(_ text: String) -> Bool {
        text.contains(where: Self.isCJK)
    }

    // MARK: - 文件

    private var exportsDirectory: URL {
        let base = exportsDirectoryOverride ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Exports", isDirectory: true)
    }

    private func ensureExportsDirectory() throws -> URL {
        let directory = exportsDirectory
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw ContactExporterError.vCardWriteFailed(error)
        }
        return directory
    }

    private func write(_ content: String, to url: URL) throws -> URL {
        guard let data = content.data(using: .utf8) else {
            throw ContactExporterError.emptyCard
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ContactExporterError.vCardWriteFailed(error)
        }
        return url
    }

    private func sanitizedFileComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        let scalars = raw.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "_"
        }
        let result = scalars.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String((result.isEmpty ? "Card" : result).prefix(36))
    }

    // MARK: - 通讯录权限

    private func ensureContactsAccess(_ store: CNContactStore) async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                store.requestAccess(for: .contacts) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw ContactExporterError.contactsPermissionDenied
            }
        default:
            throw ContactExporterError.contactsPermissionDenied
        }
    }

    // MARK: - Formatters

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()
}

// MARK: - 多值号码

private extension ContactExporter {
    func phoneValues(_ raw: String?) -> [String] {
        splitValues(raw)
    }
}
