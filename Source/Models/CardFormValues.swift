//
//  CardFormValues.swift
//  CamCardClone
//
//  校对 / 编辑表单的纯值对象。
//
//  设计约束：
//  - 表单使用「非可选字符串」承接键盘输入，提交时再统一转成 nil / 归一化值；
//  - 这是唯一允许在 UI 与 BusinessCard 之间搬运字段的中间类型；
//  - 不包含 fax：本次校对页固定 8 个核心字段，编辑时保留已有 fax 不变。
//

import Foundation

// MARK: - 表单字段

/// 校对页与编辑页的 8 个核心字段。
enum CardFormField: String, CaseIterable, Identifiable, Hashable {
    case name
    case company
    case jobTitle
    case mobile
    case phone
    case email
    case website
    case address

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "姓名"
        case .company: return "公司"
        case .jobTitle: return "职位"
        case .mobile: return "手机"
        case .phone: return "电话"
        case .email: return "邮箱"
        case .website: return "网址"
        case .address: return "地址"
        }
    }

    var systemImage: String {
        switch self {
        case .name: return "person.text.rectangle"
        case .company: return "building.2"
        case .jobTitle: return "briefcase"
        case .mobile: return "iphone"
        case .phone: return "phone"
        case .email: return "envelope"
        case .website: return "globe"
        case .address: return "mappin.and.ellipse"
        }
    }

    var placeholder: String {
        switch self {
        case .name: return "请输入姓名"
        case .company: return "请输入公司名称"
        case .jobTitle: return "请输入职位"
        case .mobile: return "请输入手机号码"
        case .phone: return "请输入办公电话"
        case .email: return "name@example.com"
        case .website: return "https://example.com"
        case .address: return "请输入地址"
        }
    }
}

// MARK: - 表单值

/// 可编辑的 8 字段表单值。空串代表「用户清空」，写入时转换为 nil。
struct CardFormValues: Equatable {
    var name: String = ""
    var company: String = ""
    var jobTitle: String = ""
    var mobile: String = ""
    var phone: String = ""
    var email: String = ""
    var website: String = ""
    var address: String = ""

    init() {}

    init(
        name: String = "",
        company: String = "",
        jobTitle: String = "",
        mobile: String = "",
        phone: String = "",
        email: String = "",
        website: String = "",
        address: String = ""
    ) {
        self.name = name
        self.company = company
        self.jobTitle = jobTitle
        self.mobile = mobile
        self.phone = phone
        self.email = email
        self.website = website
        self.address = address
    }

    init(card: BusinessCard) {
        self.init(
            name: card.name ?? "",
            company: card.company ?? "",
            jobTitle: card.jobTitle ?? "",
            mobile: card.mobile ?? "",
            phone: card.phone ?? "",
            email: card.email ?? "",
            website: card.website ?? "",
            address: card.address ?? ""
        )
    }

    init(parsed: ParsedCardFields) {
        self.init(
            name: parsed.name ?? "",
            company: parsed.company ?? "",
            jobTitle: parsed.jobTitle ?? "",
            mobile: parsed.mobile ?? "",
            phone: parsed.phone ?? "",
            email: parsed.email ?? "",
            website: parsed.website ?? "",
            address: parsed.address ?? ""
        )
    }

    // MARK: - 读取

    subscript(field: CardFormField) -> String {
        get {
            switch field {
            case .name: return name
            case .company: return company
            case .jobTitle: return jobTitle
            case .mobile: return mobile
            case .phone: return phone
            case .email: return email
            case .website: return website
            case .address: return address
            }
        }
        set {
            switch field {
            case .name: name = newValue
            case .company: company = newValue
            case .jobTitle: jobTitle = newValue
            case .mobile: mobile = newValue
            case .phone: phone = newValue
            case .email: email = newValue
            case .website: website = newValue
            case .address: address = newValue
            }
        }
    }

    /// 去除首尾空白后的值；空串返回 nil。
    func trimmedValue(for field: CardFormField) -> String? {
        let value = self[field].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var isEmpty: Bool {
        CardFormField.allCases.allSatisfy { trimmedValue(for: $0) == nil }
    }

    var filledFieldCount: Int {
        CardFormField.allCases.reduce(into: 0) { result, field in
            if trimmedValue(for: field) != nil {
                result += 1
            }
        }
    }

    /// 保存校验。返回 nil 表示通过。
    var validationError: String? {
        if trimmedValue(for: .name) == nil && trimmedValue(for: .company) == nil {
            return "请至少填写姓名或公司"
        }
        if isEmpty {
            return "请至少填写一个字段"
        }
        if let notes = trimmedValue(for: .address), notes.count > 500 {
            return "地址不能超过 500 个字符"
        }
        return nil
    }

    // MARK: - 写入

    /// 把表单值写回实体。空串一律写成 nil，随后由 `sanitize()` 负责归一化。
    /// 注意：不会改动 tags / notes / fax / 图片路径。
    func apply(to card: BusinessCard) {
        card.name = trimmedValue(for: .name)
        card.company = trimmedValue(for: .company)
        card.jobTitle = trimmedValue(for: .jobTitle)
        card.mobile = trimmedValue(for: .mobile)
        card.phone = trimmedValue(for: .phone)
        card.email = trimmedValue(for: .email)
        card.website = trimmedValue(for: .website)
        card.address = trimmedValue(for: .address)
        card.sanitize()
    }
}
