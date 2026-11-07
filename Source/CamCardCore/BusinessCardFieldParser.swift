//
//  BusinessCardFieldParser.swift
//  CamCardCore
//
//  纯本地、无网络、无机器学习依赖的名片字段解析器。
//
//  设计目标：
//  1. 只输出 OCR 原文中能够被规则明确证明的字段；无法确认时返回 nil。
//  2. 电话按 Mobile / Office / Fax 语境分类，Fax 不允许串入 mobile 或 phone。
//  3. 邮箱与网址完全基于原文；绝不从邮箱域名「推导」网址。
//  4. 同时支持中英双语、竖排空格、单行 `·` / `|` 分隔、多行地址等常见 OCR 版式。
//
//  注意：ParsedCardResult 按需求只暴露 8 个业务字段。Fax 仍在内部被识别并隔离，
//  但不会写入 mobile / phone。若上层模型需要保存传真，可复用相同的内部归类结果。
//

import Foundation

// MARK: - 结果模型

public struct ParsedCardResult: Sendable {
    public var name: String?
    public var company: String?
    public var jobTitle: String?
    public var mobile: String?
    public var phone: String?
    public var email: String?
    public var website: String?
    public var address: String?
    public var rawText: String

    public init(
        name: String? = nil,
        company: String? = nil,
        jobTitle: String? = nil,
        mobile: String? = nil,
        phone: String? = nil,
        email: String? = nil,
        website: String? = nil,
        address: String? = nil,
        rawText: String
    ) {
        self.name = name
        self.company = company
        self.jobTitle = jobTitle
        self.mobile = mobile
        self.phone = phone
        self.email = email
        self.website = website
        self.address = address
        self.rawText = rawText
    }
}

// MARK: - 解析器

public enum BusinessCardFieldParser {

    // MARK: Public API

    public static func parse(rawText: String) -> ParsedCardResult {
        let lines = makeLines(from: rawText)
        let contacts = extractContacts(from: lines)

        let address = extractAddress(from: lines)
        let companyInfo = extractCompany(from: lines, contacts: contacts, addressLines: address.lineIndexes)
        let titleInfo = extractTitle(
            from: lines,
            contacts: contacts,
            companyLineIndexes: companyInfo.candidateLineIndexes,
            addressLineIndexes: address.lineIndexes
        )
        let name = extractName(
            from: lines,
            contacts: contacts,
            companyLineIndexes: companyInfo.candidateLineIndexes,
            addressLineIndexes: address.lineIndexes,
            titleResidualNames: titleInfo.residualNames
        )

        return ParsedCardResult(
            name: name,
            company: companyInfo.value,
            jobTitle: titleInfo.value,
            mobile: contacts.mobile,
            phone: contacts.phone,
            email: contacts.email,
            website: contacts.website,
            address: address.value,
            rawText: rawText
        )
    }

    // MARK: 内部数据类型

    private struct SourceLine {
        let index: Int
        let text: String
        let isNoise: Bool
    }

    private struct ContactExtraction {
        var email: String?
        var website: String?
        var mobile: String?
        var phone: String?
        var faxCount: Int
        var contactLineIndexes: Set<Int>
        var maskedTexts: [String]
    }

    private struct AddressExtraction {
        let value: String?
        let lineIndexes: Set<Int>
    }

    private struct CompanyInfo {
        let value: String?
        let candidateLineIndexes: Set<Int>
    }

    private struct TitleInfo {
        let value: String?
        let residualNames: [NameCandidate]
    }

    private struct NameCandidate {
        let value: String
        let score: Int
        let lineIndex: Int
    }

    private enum PhoneKind: Hashable {
        case mobile
        case office
        case fax
    }

    private struct PhoneCandidate {
        let value: String
        let kind: PhoneKind?
        let lineIndex: Int
    }

    private struct AddressFragment {
        let lineIndex: Int
        let text: String
        let score: Int
    }

    private struct TitleHit {
        let text: String
        let range: NSRange
        let isChinese: Bool
    }

    private struct CompanyCandidate {
        let lineIndex: Int
        let text: String
        let score: Int
        let isChinese: Bool
    }

    // MARK: - 文本预处理

    private static func makeLines(from rawText: String) -> [SourceLine] {
        let normalizedNewlines = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let separatorSet = CharacterSet(charactersIn: "·•|｜")
        var result: [SourceLine] = []

        for physicalLine in normalizedNewlines.components(separatedBy: "\n") {
            for piece in physicalLine.components(separatedBy: separatorSet) {
                var text = piece
                    .replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")

                text = text.replacingOccurrences(
                    of: #"\s+"#,
                    with: " ",
                    options: .regularExpression
                )
                text = compactVerticalCJKIfNeeded(text)
                text = text.trimmingCharacters(
                    in: CharacterSet.whitespacesAndNewlines
                        .union(CharacterSet(charactersIn: "-–—*•·"))
                )

                guard !text.isEmpty, !text.unicodeScalars.allSatisfy({ isDecoration($0) }) else {
                    continue
                }

                result.append(
                    SourceLine(
                        index: result.count,
                        text: text,
                        isNoise: isNoiseLine(text)
                    )
                )
            }
        }

        return result
    }

    /// 竖排 OCR 常把「明道律师事务所」识别成「明 道 律 师 事 务 所」。
    /// 仅在整行由单字 CJK token 组成时去掉空格，避免破坏地址中的正常词间距
    /// （例如「……0000 号 恒隆广场」）。
    private static func compactVerticalCJKIfNeeded(_ text: String) -> String {
        let tokens = text.split(separator: " ")
        guard tokens.count >= 2,
              tokens.allSatisfy({ token in
                  token.count == 1 && token.unicodeScalars.allSatisfy {
                      (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                  }
              }) else {
            return text
        }
        return tokens.joined()
    }

    private static func isNoiseLine(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("confidential") || lower.contains("机密") {
            return true
        }
        if lower.range(
            of: #"^(?:scanned?|scan\s+date|date|time|page)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        return false
    }

    private static func isDecoration(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0D {
            return true
        }
        return (0x2000...0x206F).contains(value) || (0x2E00...0x2E7F).contains(value)
    }

    // MARK: - 联系方式

    private static func extractContacts(from lines: [SourceLine]) -> ContactExtraction {
        var result = ContactExtraction(
            email: nil,
            website: nil,
            mobile: nil,
            phone: nil,
            faxCount: 0,
            contactLineIndexes: [],
            maskedTexts: lines.map(\.text)
        )

        var explicitWebsite: String?
        var bareWebsite: String?

        var mobiles: [String] = []
        var offices: [String] = []
        var ambiguous: [PhoneCandidate] = []
        var seenMobiles = Set<String>()
        var seenOffices = Set<String>()

        for line in lines {
            let original = line.text
            let originalNSString = original as NSString
            let mutable = NSMutableString(string: original)
            var touchedContact = false

            // 1) Email：先识别并全部打码，防止邮箱域名被误认为网址。
            let emailMatches = matches(emailRegex, in: original)
            if !emailMatches.isEmpty {
                touchedContact = true
            }
            for match in emailMatches {
                let candidate = originalNSString.substring(with: match.range)
                if result.email == nil, let normalized = normalizeEmail(candidate) {
                    result.email = normalized
                }
            }
            mask(ranges: emailMatches.map(\.range), in: mutable)

            // 2) 显式 URL（http://、https://、www.）。
            let explicitMatches = matches(explicitWebsiteRegex, in: String(mutable))
            let explicitRanges = explicitMatches.map(\.range)
            if !explicitRanges.isEmpty {
                touchedContact = true
            }
            for match in explicitMatches {
                let candidate = (String(mutable) as NSString).substring(with: match.range)
                if explicitWebsite == nil,
                   let normalized = normalizeWebsite(candidate, requireKnownTLD: false) {
                    explicitWebsite = normalized
                }
            }
            mask(ranges: explicitRanges, in: mutable)

            // 3) 裸域名（example.com / example.co.uk）。
            let bareMatches = matches(bareWebsiteRegex, in: String(mutable))
            let bareRanges = bareMatches.map(\.range)
            if !bareRanges.isEmpty {
                touchedContact = true
            }
            for match in bareMatches {
                let candidate = (String(mutable) as NSString).substring(with: match.range)
                if bareWebsite == nil,
                   let normalized = normalizeWebsite(candidate, requireKnownTLD: true) {
                    bareWebsite = normalized
                }
            }
            mask(ranges: bareRanges, in: mutable)

            // 4) 电话。此时邮箱和网址已被替换为等长空格，标签仍保留在原文中。
            let phoneMatches = matches(phoneRegex, in: String(mutable))
            if !phoneMatches.isEmpty {
                touchedContact = true
            }
            for match in phoneMatches {
                let raw = originalNSString.substring(with: match.range)
                guard !looksLikeDate(raw), let normalized = normalizePhone(raw) else {
                    continue
                }

                let prefix = originalNSString.substring(to: match.range.location)
                let suffix = originalNSString.substring(from: NSMaxRange(match.range))
                let kind = classifyPhone(
                    value: normalized,
                    prefix: prefix,
                    suffix: suffix,
                    line: original
                )

                if kind == nil {
                    // 无标签的号码只有在格式足够明确时才接受，宁缺毋滥。
                    let digitCount = normalized.filter(\.isNumber).count
                    guard normalized.hasPrefix("+") || digitCount >= 10 else {
                        continue
                    }
                }

                let candidate = PhoneCandidate(
                    value: normalized,
                    kind: kind,
                    lineIndex: line.index
                )

                switch kind {
                case .mobile:
                    if seenMobiles.insert(normalized).inserted {
                        mobiles.append(normalized)
                    }
                case .office:
                    if seenOffices.insert(normalized).inserted {
                        offices.append(normalized)
                    }
                case .fax:
                    result.faxCount += 1
                case .none:
                    ambiguous.append(candidate)
                }
            }
            mask(ranges: phoneMatches.map(\.range), in: mutable)

            if touchedContact {
                result.contactLineIndexes.insert(line.index)
            }
            result.maskedTexts[line.index] = String(mutable)
        }

        result.website = explicitWebsite ?? bareWebsite

        // 无标签号码按版面顺序兜底：第一个视为手机，第二个视为办公电话。
        // 第三个及之后的裸号码无法可靠区分，直接忽略，避免猜测。
        for candidate in ambiguous {
            if mobiles.isEmpty {
                if seenMobiles.insert(candidate.value).inserted {
                    mobiles.append(candidate.value)
                }
            } else if offices.isEmpty {
                if seenOffices.insert(candidate.value).inserted {
                    offices.append(candidate.value)
                }
            }
        }

        // 同一号码若同时被标成 Mobile 与 Office，以 Mobile 为准。
        let mobileSet = Set(mobiles)
        offices.removeAll { mobileSet.contains($0) }

        result.mobile = mobiles.isEmpty ? nil : mobiles.joined(separator: " / ")
        result.phone = offices.isEmpty ? nil : offices.joined(separator: " / ")
        return result
    }

    private static let emailRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w.%+\-])[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,24}(?![\w\-])"#
    )

    private static let explicitWebsiteRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?://|www\.)[^\s<>"'“”‘’]+"#
    )

    private static let bareWebsiteRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![A-Za-z0-9@._-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}(?::\d{2,5})?(?:/[^\s<>"'“”‘’]*)?"#
    )

    private static let phoneRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}@._+\-])(?:\+\s*)?(?:\(\s*\d{1,4}\s*\)[\s.\-]*)?\d(?:[\d\s().\-]{5,}\d)(?![\p{L}\p{N}@._+\-])"#
    )

    private static let imageFileExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "svg", "bmp",
        "tif", "tiff", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "txt", "zip", "rar", "mp4", "mov"
    ]

    private static let commonTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "io", "ai", "co",
        "cn", "uk", "us", "de", "fr", "jp", "kr", "hk", "tw", "sg", "au",
        "ca", "ch", "nl", "se", "no", "fi", "dk", "es", "it", "ru", "br",
        "mx", "in", "nz", "ie", "be", "at", "pl", "pt", "cz", "gr", "tr",
        "za", "ae", "sa", "il", "my", "th", "vn", "id", "ph", "eu",
        "app", "dev", "tech", "online", "site", "xyz", "info", "biz", "name",
        "pro", "mobi", "asia", "club", "shop", "store", "design", "studio",
        "agency", "consulting", "solutions", "systems", "services", "global",
        "group", "world", "life", "live", "news", "media", "digital", "network",
        "cloud", "software"
    ]

    private static func normalizeEmail(_ raw: String) -> String? {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.contains("..") else { return nil }

        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }

        let domain = String(parts[1])
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              let tld = labels.last?.lowercased(),
              !imageFileExtensions.contains(tld) else {
            return nil
        }

        return value
    }

    private static func normalizeWebsite(_ raw: String, requireKnownTLD: Bool) -> String? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate = candidate.trimmingCharacters(
            in: CharacterSet(charactersIn: ".,;:!?)]}，。；：！？、）】》")
        )
        guard !candidate.isEmpty, !candidate.contains("@") else { return nil }

        let lower = candidate.lowercased()
        let hasScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        let hasWWW = lower.hasPrefix("www.")
        var urlString = candidate

        if !hasScheme {
            urlString = "https://" + candidate
        }

        guard var components = URLComponents(string: urlString),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        let hostLower = host.lowercased()
        let hostLabels = hostLower.split(separator: ".", omittingEmptySubsequences: false)
        guard hostLabels.count >= 2,
              hostLabels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              let tld = hostLabels.last,
              !imageFileExtensions.contains(String(tld)) else {
            return nil
        }

        if requireKnownTLD && !hasWWW && !commonTLDs.contains(String(tld)) {
            return nil
        }

        components.scheme = components.scheme?.lowercased()
        components.host = hostLower

        guard var normalized = components.string else { return nil }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func looksLikeDate(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(
            of: #"^(?:19|20)\d{2}\s*[-/.]\s*\d{1,2}\s*[-/.]\s*\d{1,2}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func normalizePhone(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var hasPlus = trimmed.hasPrefix("+")
        var digits = String(trimmed.filter { $0.isASCII && $0.isNumber })

        guard (7...15).contains(digits.count) else { return nil }

        // 中国大陆手机：+86 前缀归一化为国内 11 位格式。
        if hasPlus, digits.hasPrefix("86") {
            let rest = String(digits.dropFirst(2))
            if rest.count == 11, rest.first == "1", let second = rest.dropFirst().first,
               ("3"..."9").contains(second) {
                digits = rest
                hasPlus = false
            } else if rest.count == 10, rest.first != "0" {
                // +86 10 xxxx xxxx → 010xxxxxxxx（补国内长途 0）。
                digits = "0" + rest
                hasPlus = false
            }
        }

        return (hasPlus ? "+" : "") + digits
    }

    private static func classifyPhone(
        value: String,
        prefix: String,
        suffix: String,
        line: String
    ) -> PhoneKind? {
        if let affixKind = phoneKindFromAffix(prefix: prefix, suffix: suffix) {
            return affixKind
        }
        if let lineKind = phoneKindFromLine(line) {
            return lineKind
        }

        let digits = value.filter(\.isNumber)
        if !value.hasPrefix("+"), digits.count == 11,
           digits.first == "1", let second = digits.dropFirst().first,
           ("3"..."9").contains(second) {
            return .mobile
        }
        if !value.hasPrefix("+"),
           digits.count >= 10,
           digits.count <= 12,
           digits.first == "0" {
            return .office
        }
        if !value.hasPrefix("+"), digits.hasPrefix("400") || digits.hasPrefix("800") {
            return .office
        }
        return nil
    }

    private static let mobilePrefixRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[\s:：,;；|/()\[\]（）【】])(?:mobile|cell(?:ular)?|m|手机\s*\d*|移动电话|手提电话|行動電話|携帯電話)\s*[:：]?\s*$"#
    )

    private static let officePrefixRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[\s:：,;；|/()\[\]（）【】])(?:tel(?:ephone)?|phone|office|direct|o|t|电话|座机|办公电话|公司电话|总机)\s*[:：]?\s*$"#
    )

    private static let faxPrefixRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[\s:：,;；|/()\[\]（）【】])(?:fax|facsimile|f|传真)\s*[:：]?\s*$"#
    )

    private static let mobileSuffixRegex = try! NSRegularExpression(
        pattern: #"(?i)^\s*[\(\[（【]?\s*(?:mobile|cell(?:ular)?|m|手机\s*\d*|移动电话|手提电话)\s*[\)\]）】]?\s*(?:$|[,;；|/])"#
    )

    private static let officeSuffixRegex = try! NSRegularExpression(
        pattern: #"(?i)^\s*[\(\[（【]?\s*(?:tel(?:ephone)?|phone|office|direct|o|t|电话|座机)\s*[\)\]）】]?\s*(?:$|[,;；|/])"#
    )

    private static let faxSuffixRegex = try! NSRegularExpression(
        pattern: #"(?i)^\s*[\(\[（【]?\s*(?:fax|facsimile|f|传真)\s*[\)\]）】]?\s*(?:$|[,;；|/])"#
    )

    private static func phoneKindFromAffix(prefix: String, suffix: String) -> PhoneKind? {
        let prefixRange = NSRange(prefix.startIndex..., in: prefix)
        let suffixRange = NSRange(suffix.startIndex..., in: suffix)

        if faxPrefixRegex.firstMatch(in: prefix, range: prefixRange) != nil ||
            faxSuffixRegex.firstMatch(in: suffix, range: suffixRange) != nil {
            return .fax
        }
        if mobilePrefixRegex.firstMatch(in: prefix, range: prefixRange) != nil ||
            mobileSuffixRegex.firstMatch(in: suffix, range: suffixRange) != nil {
            return .mobile
        }
        if officePrefixRegex.firstMatch(in: prefix, range: prefixRange) != nil ||
            officeSuffixRegex.firstMatch(in: suffix, range: suffixRange) != nil {
            return .office
        }
        return nil
    }

    private static func phoneKindFromLine(_ line: String) -> PhoneKind? {
        let lower = line.lowercased()
        var kinds = Set<PhoneKind>()

        if lower.range(of: #"(?i)\b(?:fax|facsimile)\b|传真"#, options: .regularExpression) != nil {
            kinds.insert(.fax)
        }
        if lower.range(of: #"(?i)\b(?:mobile|cell(?:ular)?)\b|手机|移动电话|手提电话"#, options: .regularExpression) != nil {
            kinds.insert(.mobile)
        }
        if lower.range(of: #"(?i)\b(?:tel|telephone|phone|office|direct)\b|电话|座机|办公电话|公司电话|总机"#, options: .regularExpression) != nil {
            kinds.insert(.office)
        }

        // 单字母标签只在行首时生效，避免把普通英文单词中的 m/t/f 当成电话标签。
        if lower.range(of: #"^\s*m\s*[:：.]?\s*\+?\d"#, options: .regularExpression) != nil {
            kinds.insert(.mobile)
        }
        if lower.range(of: #"^\s*[to]\s*[:：.]?\s*\+?\d"#, options: .regularExpression) != nil {
            kinds.insert(.office)
        }
        if lower.range(of: #"^\s*f\s*[:：.]?\s*\+?\d"#, options: .regularExpression) != nil {
            kinds.insert(.fax)
        }

        return kinds.count == 1 ? kinds.first : nil
    }

    // MARK: - 地址

    private static func extractAddress(from lines: [SourceLine]) -> AddressExtraction {
        var fragments: [AddressFragment] = []

        for line in lines where !line.isNoise {
            let cleaned = cleanAddressText(line.text)
            guard !cleaned.isEmpty else { continue }
            let score = addressScore(cleaned)
            guard score >= 3 else { continue }
            fragments.append(AddressFragment(lineIndex: line.index, text: cleaned, score: score))
        }

        guard !fragments.isEmpty else {
            return AddressExtraction(value: nil, lineIndexes: [])
        }

        var groups: [[AddressFragment]] = []
        for fragment in fragments {
            if let last = groups.last?.last, last.lineIndex + 1 == fragment.lineIndex {
                groups[groups.count - 1].append(fragment)
            } else {
                groups.append([fragment])
            }
        }

        let usableGroups = groups.filter { group in
            guard let maxScore = group.map(\.score).max() else { return false }
            return maxScore >= 4 || group.count >= 2
        }
        guard let group = usableGroups.first else {
            return AddressExtraction(value: nil, lineIndexes: [])
        }

        let value = joinAddress(group.map(\.text))
        return AddressExtraction(value: value, lineIndexes: Set(group.map(\.lineIndex)))
    }

    private static func cleanAddressText(_ text: String) -> String {
        var value = text
        let labelPatterns = [
            #"(?i)^(?:公司)?地址\s*[:：]\s*"#,
            #"(?i)^(?:address|addr|add)\.?\s*[:：]\s*"#
        ]
        for pattern in labelPatterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        value = value.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ",;，；"))
        )
        return value
    }

    private static func addressScore(_ text: String) -> Int {
        let hasDigit = text.unicodeScalars.contains { (0x30...0x39).contains($0.value) }

        if containsCJK(text) {
            let hasRoad = text.range(
                of: #"(?:路|街|大道|大街|巷|弄|胡同|道)"#,
                options: .regularExpression
            ) != nil
            let hasNumberMark = text.range(
                of: #"(?:号|栋|幢|座|楼|层|室|单元|门牌)"#,
                options: .regularExpression
            ) != nil
            let hasBuilding = text.range(
                of: #"(?:大厦|广场|园区|工业园|花园|公寓|小区|中心|写字楼|商务楼|医院|学校|大学|酒店)"#,
                options: .regularExpression
            ) != nil
            let regionCount = countMatches(
                #"(?:省|市|区|县|镇|乡|村)"#,
                in: text
            )

            var score = 0
            if hasRoad && (hasNumberMark || hasDigit) {
                score = max(score, 5)
            }
            if hasBuilding && (hasNumberMark || hasDigit) {
                score = max(score, 4)
            }
            // 「北京市海淀区清华园 1 号」这类没有“路/街”字样的地址。
            if regionCount >= 2 && hasNumberMark && hasDigit {
                score = max(score, 5)
            } else if regionCount >= 2 {
                score = max(score, 3)
            }
            if hasNumberMark && hasDigit {
                score = max(score, 3)
            }
            return score
        }

        let hasStreet = text.range(
            of: #"(?i)\b(?:street|st\.?|road|rd\.?|avenue|ave\.?|boulevard|blvd\.?|drive|dr\.?|lane|ln\.?|way|court|ct\.?|place|pl\.?|square|passage|wharf|highway|hwy|parkway|pkwy|terrace|row|unit|suite|floor|building|house|plaza)\b"#,
            options: .regularExpression
        ) != nil
        let hasPostalCode = text.range(
            of: #"(?i)\b(?:[A-Z]{2}\s+\d{5}(?:-\d{4})?|[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}|[A-Z]\d[A-Z]\s*\d[A-Z]\d)\b"#,
            options: .regularExpression
        ) != nil
        let startsWithNumber = text.range(
            of: #"^\s*\d+[A-Za-z]?\s+"#,
            options: .regularExpression
        ) != nil

        var score = 0
        if hasStreet && hasDigit {
            score = max(score, 5)
        }
        if hasPostalCode && hasDigit {
            score = max(score, 4)
        }
        if startsWithNumber && hasStreet {
            score = max(score, 5)
        }
        return score
    }

    private static func joinAddress(_ fragments: [String]) -> String {
        var result = ""
        for fragment in fragments {
            guard !fragment.isEmpty else { continue }
            if result.isEmpty {
                result = fragment
                continue
            }

            let separator = (containsCJK(result) && containsCJK(fragment)) ? "" : ", "
            result += separator + fragment
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 公司

    private static func extractCompany(
        from lines: [SourceLine],
        contacts: ContactExtraction,
        addressLines: Set<Int>
    ) -> CompanyInfo {
        var candidates: [CompanyCandidate] = []

        for line in lines where !line.isNoise {
            guard !contacts.contactLineIndexes.contains(line.index),
                  !addressLines.contains(line.index) else {
                continue
            }

            let text = cleanCompanyText(contacts.maskedTexts[line.index])
            guard !text.isEmpty else { continue }

            let titleHits = matchTitleHits(in: text)
            let score = companyScore(text)
            guard score > 0 else { continue }

            // 「品牌文化总监」这类职位行可能包含行业词，不能因为「文化」就判成公司。
            if !titleHits.isEmpty && score < 100 {
                continue
            }

            candidates.append(
                CompanyCandidate(
                    lineIndex: line.index,
                    text: text,
                    score: score,
                    isChinese: containsCJK(text)
                )
            )
        }

        guard !candidates.isEmpty else {
            return CompanyInfo(value: nil, candidateLineIndexes: [])
        }

        // 中英双语名片常把公司写成相邻两行。此时优先保留中文行，
        // 即便英文行带有更「强硬」的 Ltd./LLC 后缀。
        let byLine = candidates.sorted { $0.lineIndex < $1.lineIndex }
        var groups: [[CompanyCandidate]] = []
        for candidate in byLine {
            if let last = groups.last?.last, last.lineIndex + 1 == candidate.lineIndex {
                groups[groups.count - 1].append(candidate)
            } else {
                groups.append([candidate])
            }
        }

        let ranked = groups.compactMap { group -> (score: Int, chosen: CompanyCandidate)? in
            guard let best = group.max(by: { $0.score < $1.score }) else { return nil }
            let hasChinese = group.contains(where: \.isChinese)
            let hasLatin = group.contains(where: { !$0.isChinese })
            let score = best.score + (hasChinese && hasLatin ? 10 : 0)
            let chosen: CompanyCandidate
            if hasChinese && hasLatin {
                chosen = group
                    .filter(\.isChinese)
                    .max(by: { $0.score < $1.score }) ?? best
            } else {
                chosen = best
            }
            return (score, chosen)
        }

        let selected = ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.chosen.lineIndex < rhs.chosen.lineIndex
        }.first

        return CompanyInfo(
            value: selected?.chosen.text,
            candidateLineIndexes: Set(candidates.map(\.lineIndex))
        )
    }

    private static let chineseCompanyMarkers: [(String, Int)] = [
        ("股份有限公司", 125), ("有限责任公司", 125), ("有限公司", 120),
        ("事务所", 105), ("研究院", 105), ("设计院", 105),
        ("集团", 100), ("公司", 100), ("大学", 100), ("学院", 100),
        ("医院", 100), ("工作室", 100), ("银行", 95), ("证券", 95),
        ("资本", 90), ("传媒", 90), ("科技", 85), ("咨询", 85),
        ("餐饮", 85), ("酒店", 85), ("制造", 85), ("实业", 85),
        ("软件", 85), ("文化", 80), ("音乐", 80), ("网络", 80),
        ("智能", 80), ("医疗", 80), ("教育", 75), ("建筑", 75),
        ("信息", 75), ("健康", 75), ("数据", 70), ("生活", 65)
    ]

    private static let englishCompanyWords: [String: Int] = [
        "inc": 120, "llc": 120, "llp": 120,
        "co": 110, "ltd": 110, "limited": 110, "corp": 110,
        "corporation": 110, "gmbh": 110, "pte": 105, "pty": 105,
        "group": 100, "studio": 95, "consulting": 95, "partners": 95,
        "ventures": 95, "associates": 95, "foundation": 95,
        "capital": 90, "holdings": 90, "hotels": 90, "media": 90,
        "labs": 90, "supply": 90, "industries": 90, "enterprises": 90,
        "software": 90, "technology": 85, "technologies": 85,
        "analytics": 85, "solutions": 85, "design": 85, "architect": 85,
        "architects": 85, "architecture": 85, "systems": 85,
        "services": 85, "agency": 85, "education": 80, "music": 80,
        "freight": 80, "hospital": 100, "university": 100,
        "college": 100, "bank": 95, "securities": 95, "institute": 100
    ]

    private static func companyScore(_ text: String) -> Int {
        var score = 0

        for (marker, value) in chineseCompanyMarkers where text.contains(marker) {
            score = max(score, value)
        }

        let englishWords = text
            .lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0 == "&" })
            .map(String.init)
        for word in englishWords {
            if let value = englishCompanyWords[word] {
                score = max(score, value)
            }
        }

        // 无行业后缀的英文品牌：Fold & Field / Pike & Rowe。
        if score == 0, text.range(
            of: #"^[A-Za-z][A-Za-z'’.\-]*(?:\s*&\s*[A-Za-z][A-Za-z'’.\-]*)+$"#,
            options: .regularExpression
        ) != nil {
            score = 70
        }

        return score
    }

    private static func cleanCompanyText(_ text: String) -> String {
        var value = text
        let patterns = [
            #"(?i)^(?:company|company\s+name|org|organization)\s*[:：]\s*"#,
            #"^(?:公司|公司名称|单位)\s*[:：]\s*"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return value.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ",;，；|"))
        )
    }

    // MARK: - 职位

    private static func extractTitle(
        from lines: [SourceLine],
        contacts: ContactExtraction,
        companyLineIndexes: Set<Int>,
        addressLineIndexes: Set<Int>
    ) -> TitleInfo {
        var chineseTitles: [String] = []
        var englishTitles: [String] = []
        var residualNames: [NameCandidate] = []
        var seenChinese = Set<String>()
        var seenEnglish = Set<String>()

        for line in lines where !line.isNoise {
            guard !contacts.contactLineIndexes.contains(line.index),
                  !companyLineIndexes.contains(line.index),
                  !addressLineIndexes.contains(line.index) else {
                continue
            }

            let text = line.text
            let hits = matchTitleHits(in: text)
            guard !hits.isEmpty else { continue }

            for hit in hits {
                let title = hit.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                if hit.isChinese {
                    if seenChinese.insert(title).inserted {
                        chineseTitles.append(title)
                    }
                } else {
                    let key = title.lowercased()
                    if seenEnglish.insert(key).inserted {
                        englishTitles.append(title)
                    }
                }
            }

            let mutable = NSMutableString(string: text)
            for hit in hits.reversed() {
                mutable.replaceCharacters(in: hit.range, with: " ")
            }
            let residual = cleanResidualName(String(mutable))
            if let name = parsePersonName(residual) {
                residualNames.append(
                    NameCandidate(value: name, score: 60, lineIndex: line.index)
                )
            }
        }

        let orderedTitles = chineseTitles + englishTitles
        let title = orderedTitles.isEmpty ? nil : orderedTitles.joined(separator: " / ")
        return TitleInfo(value: title, residualNames: residualNames)
    }

    private static func cleanResidualName(_ text: String) -> String {
        var value = text.replacingOccurrences(
            of: #"[/|,;:·•]+"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return value.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "-–—()（）[]【】"))
        )
    }

    private static let chineseTitleTerms: [String] = [
        "首席执行官", "首席技术官", "首席财务官", "首席运营官", "首席市场官",
        "主持建筑师", "执业律师", "高级工程师", "数据架构师", "副主任医师", "主任医师",
        "独立摄影师", "独立插画师", "品牌主理人", "教研负责人", "技术负责人",
        "内容运营经理", "高级合伙人", "项目经理", "门店经理", "采购主管",
        "投资总监", "市场总监", "产品总监", "销售总监", "运营总监", "技术总监",
        "总经理", "副总经理", "联合创始人", "创始人", "合伙人", "教授", "副教授",
        "医师", "工程师", "律师", "建筑师", "设计师", "摄影师", "插画师",
        "艺人经纪", "经纪人", "经纪", "顾问", "分析师", "研究员", "架构师",
        "主理人", "总监", "经理", "主管", "负责人", "助理", "专员", "代表",
        "会计师", "审计师", "总裁", "董事长", "董事"
    ].sorted { $0.count > $1.count }

    private static let chineseTitleRegex: NSRegularExpression = {
        let pattern = chineseTitleTerms
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let englishTitleRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<!\p{L})(?:principal\s+architect|attorney\s+at\s+law|head\s+of\s+[a-z][a-z&'\-]*(?:\s+[a-z][a-z&'\-]*){0,2}|(?:director|manager|head|chief|vp|svp|evp)\s+of\s+[a-z][a-z&'\-]*(?:\s+[a-z][a-z&'\-]*){0,2}|(?:vp|svp|evp)\s+[a-z][a-z&'\-]*(?:\s+[a-z][a-z&'\-]*){0,2}|(?:[a-z][a-z&'\-]*\s+){0,3}(?:director|manager|engineer|professor|founder|co-founder|partner|principal|attorney|architect|illustrator|consultant|analyst|designer|developer|specialist|coordinator|supervisor|executive|officer|president|chairman|scientist|researcher|accountant|lawyer|physician|editor|producer|agent|representative))(?!\p{L})"#
    )

    private static func matchTitleHits(in text: String) -> [TitleHit] {
        var hits: [TitleHit] = []
        let fullRange = NSRange(text.startIndex..., in: text)

        for match in chineseTitleRegex.matches(in: text, range: fullRange) {
            let value = (text as NSString).substring(with: match.range)
            hits.append(TitleHit(text: value, range: match.range, isChinese: true))
        }
        for match in englishTitleRegex.matches(in: text, range: fullRange) {
            let value = (text as NSString).substring(with: match.range)
            hits.append(TitleHit(text: value, range: match.range, isChinese: false))
        }

        hits.sort {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length > $1.range.length
        }

        var nonOverlapping: [TitleHit] = []
        for hit in hits {
            if nonOverlapping.contains(where: { NSIntersectionRange($0.range, hit.range).length > 0 }) {
                continue
            }
            nonOverlapping.append(hit)
        }
        return nonOverlapping
    }

    // MARK: - 姓名

    private static func extractName(
        from lines: [SourceLine],
        contacts: ContactExtraction,
        companyLineIndexes: Set<Int>,
        addressLineIndexes: Set<Int>,
        titleResidualNames: [NameCandidate]
    ) -> String? {
        var candidates = titleResidualNames

        for line in lines where !line.isNoise {
            guard !contacts.contactLineIndexes.contains(line.index),
                  !companyLineIndexes.contains(line.index),
                  !addressLineIndexes.contains(line.index) else {
                continue
            }

            if !matchTitleHits(in: line.text).isEmpty {
                // 职位行只接受「职位 + 姓名」形式抽取出的 residual name。
                continue
            }

            let cleaned = cleanNameText(contacts.maskedTexts[line.index])
            guard let name = parsePersonName(cleaned) else { continue }

            var score = 10
            if containsCJK(name) && name.range(
                of: #"[\u4E00-\u9FFF]{2,4}\s+[A-Za-z]"#,
                options: .regularExpression
            ) != nil {
                score += 30
            } else if containsCJK(name) {
                score += 5
            } else {
                score += 20
            }
            candidates.append(
                NameCandidate(value: name, score: score, lineIndex: line.index)
            )
        }

        guard !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.lineIndex < $1.lineIndex
        }
        return sorted.first?.value
    }

    private static func cleanNameText(_ text: String) -> String {
        var value = text
        let patterns = [
            #"(?i)^(?:name|contact)\s*[:：]\s*"#,
            #"^(?:姓名|名字|联系人)\s*[:：]\s*"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return value.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ",;，；|/"))
        )
    }

    private static let bilingualNameRegex = try! NSRegularExpression(
        pattern: #"^([\u4E00-\u9FFF]{2,4})\s+([A-Z][A-Za-z'’.\-]*(?:\s+(?:[A-Z][A-Za-z'’.\-]*|Jr\.?|Sr\.?|II|III|IV)){1,3})$"#
    )

    private static let chineseNameRegex = try! NSRegularExpression(
        pattern: #"^[\u4E00-\u9FFF]{2,4}$"#
    )

    private static func parsePersonName(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 48,
              value.rangeOfCharacter(from: CharacterSet.decimalDigits) == nil,
              !value.contains("@"),
              !value.contains("www."),
              !value.lowercased().contains("http") else {
            return nil
        }

        let fullRange = NSRange(value.startIndex..., in: value)

        if let match = bilingualNameRegex.firstMatch(in: value, range: fullRange) {
            let chinese = (value as NSString).substring(with: match.range(at: 1))
            let english = (value as NSString).substring(with: match.range(at: 2))
            guard !containsCompanyMarker(chinese),
                  !containsChineseTitle(chinese),
                  isCleanEnglishName(english) else {
                return nil
            }
            return "\(chinese) \(english)"
        }

        if chineseNameRegex.firstMatch(in: value, range: fullRange) != nil {
            guard !containsCompanyMarker(value), !containsChineseTitle(value) else {
                return nil
            }
            return value
        }

        guard isCleanEnglishName(value) else { return nil }
        return value
    }

    private static func isCleanEnglishName(_ text: String) -> Bool {
        guard !containsCJK(text),
              !text.contains("&"),
              !text.contains(","),
              !text.contains(";"),
              !text.contains(":"),
              !text.contains("|"),
              !text.contains("/") else {
            return false
        }

        let tokens = text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard (2...4).contains(tokens.count) else { return false }

        let suffixSet: Set<String> = ["jr", "sr", "ii", "iii", "iv", "phd", "mba", "esq"]
        let lowercasedText = text.lowercased()
        for word in englishCompanyWords.keys where tokenSet(lowercasedText).contains(word) {
            return false
        }
        for word in ["the", "and", "of", "for", "at", "in", "director", "manager",
                     "engineer", "professor", "founder", "partner", "principal",
                     "attorney", "architect", "illustrator", "consultant", "analyst",
                     "designer", "developer", "specialist", "coordinator", "supervisor",
                     "executive", "officer", "president", "chairman", "scientist",
                     "researcher", "accountant", "lawyer", "physician", "editor",
                     "producer", "agent", "representative"] {
            if tokenSet(lowercasedText).contains(word) {
                return false
            }
        }

        for token in tokens {
            let normalized = token
                .replacingOccurrences(of: ".", with: "")
                .lowercased()
            if suffixSet.contains(normalized) {
                continue
            }
            if token.range(of: #"^[A-Z]\.$"#, options: .regularExpression) != nil {
                continue
            }
            guard token.range(of: #"^[A-Z][A-Za-z'’.\-]+$"#, options: .regularExpression) != nil,
                  token.rangeOfCharacter(from: .lowercaseLetters) != nil else {
                return false
            }
        }

        return true
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(
            text
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: { $0.isWhitespace || $0 == "&" })
                .map { $0.lowercased() }
        )
    }

    private static func containsCompanyMarker(_ text: String) -> Bool {
        if chineseCompanyMarkers.contains(where: { text.contains($0.0) }) {
            return true
        }
        let tokens = tokenSet(text)
        return englishCompanyWords.keys.contains { tokens.contains($0) }
    }

    private static func containsChineseTitle(_ text: String) -> Bool {
        chineseTitleTerms.contains { text.contains($0) }
    }

    // MARK: - 通用工具

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func mask(ranges: [NSRange], in string: NSMutableString) {
        for range in ranges.reversed() {
            string.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }
    }

    private static func countMatches(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
