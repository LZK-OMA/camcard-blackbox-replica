//
//  BusinessCardFieldParserTests.swift
//  CamCardCoreTests
//
//  覆盖重点：
//  - 中英双语 + Mobile / Office / Fax 多号码归类
//  - 原文缺失 Website 时必须为 nil，且不得从邮箱域名推导
//  - Fax 必须被隔离，不能污染 mobile / phone
//  - 人名与公司名相似时的区分（Jordan Lee vs Lee Consulting）
//  - 竖排 CJK、`·` 分隔单行、多行地址
//

import XCTest
@testable import CamCardCore

final class BusinessCardFieldParserTests: XCTestCase {

    // MARK: - 1. 中英双语 + 三种电话

    func testBilingualCard_classifiesMobileOfficeAndFaxSeparately() {
        let rawText = [
            "Lanting International Hotels Group",
            "澜庭国际酒店集团",
            "周慕青  Zhou Muqing",
            "Marketing Director / 市场总监",
            "Mobile: +86 136 0000 5555",
            "Office: 010-0000 6666",
            "Fax: 010-0000 7777",
            "muqing.zhou@example.com",
            "www.example.com/lanting",
            "北京市朝阳区建国路 0000 号 澜庭大厦 18 层"
        ].joined(separator: "\n")

        let result = BusinessCardFieldParser.parse(rawText: rawText)

        XCTAssertEqual(result.name, "周慕青 Zhou Muqing")
        XCTAssertEqual(result.company, "澜庭国际酒店集团")
        XCTAssertEqual(result.jobTitle, "市场总监 / Marketing Director")
        XCTAssertEqual(result.mobile, "13600005555")
        XCTAssertEqual(result.phone, "01000006666", "Office 必须进入 phone，且不能包含 Fax")
        XCTAssertEqual(result.email, "muqing.zhou@example.com")
        XCTAssertEqual(result.website, "https://www.example.com/lanting")
        XCTAssertEqual(result.address, "北京市朝阳区建国路 0000 号 澜庭大厦 18 层")
        XCTAssertEqual(result.rawText, rawText)
    }

    // MARK: - 2. 缺失 Website 必须为 nil，不能从邮箱推导

    func testMissingWebsite_isNil_evenWhenEmailExists() {
        let rawText = [
            "Northbridge Analytics Ltd.",
            "Daniel Whitfield",
            "Head of Research",
            "T 202.555.0177",
            "Daniel.Whitfield@Example.com",
            "1200 K Street NW, Suite 400, Washington, DC 20005"
        ].joined(separator: "\n")

        let result = BusinessCardFieldParser.parse(rawText: rawText)

        XCTAssertEqual(result.name, "Daniel Whitfield")
        XCTAssertEqual(result.company, "Northbridge Analytics Ltd.")
        XCTAssertEqual(result.jobTitle, "Head of Research")
        XCTAssertNil(result.mobile, "只有 Office 号码时不能把 phone 复制到 mobile")
        XCTAssertEqual(result.phone, "2025550177")
        XCTAssertEqual(result.email, "daniel.whitfield@example.com")
        XCTAssertNil(result.website, "原文没有网址，禁止从 example.com 邮箱域名推导网址")
        XCTAssertEqual(result.address, "1200 K Street NW, Suite 400, Washington, DC 20005")
    }

    func testMissingEmailAndWebsite_areBothNil() {
        let rawText = [
            "衡远咨询（上海）有限公司",
            "高级合伙人",
            "林知微",
            "手机 139 0000 1111",
            "电话 021-0000 2222",
            "上海市静安区南京西路 0000 号 恒隆广场 2 座 3301"
        ].joined(separator: "\n")

        let result = BusinessCardFieldParser.parse(rawText: rawText)

        XCTAssertEqual(result.name, "林知微")
        XCTAssertEqual(result.company, "衡远咨询（上海）有限公司")
        XCTAssertEqual(result.jobTitle, "高级合伙人")
        XCTAssertEqual(result.mobile, "13900001111")
        XCTAssertEqual(result.phone, "02100002222")
        XCTAssertNil(result.email)
        XCTAssertNil(result.website)
        XCTAssertEqual(result.address, "上海市静安区南京西路 0000 号 恒隆广场 2 座 3301")
    }

    // MARK: - 3. Fax 隔离

    func testFax_neverLeaksIntoPhoneOrMobile() {
        let rawText = [
            "Lee Consulting",
            "Jordan Lee",
            "Senior Manager",
            "Mobile: +1 212 555 0100",
            "Office: +1 212 555 0101",
            "Fax: +1 212 555 0102",
            "jordan.lee@example.com"
        ].joined(separator: "\n")

        let result = BusinessCardFieldParser.parse(rawText: rawText)

        XCTAssertEqual(result.name, "Jordan Lee")
        XCTAssertEqual(result.company, "Lee Consulting")
        XCTAssertEqual(result.jobTitle, "Senior Manager")
        XCTAssertEqual(result.mobile, "+12125550100")
        XCTAssertEqual(result.phone, "+12125550101")
        XCTAssertNotEqual(result.phone, "+12125550102")
        XCTAssertNil(result.website)
    }

    func testFaxOnlyCard_hasNoMobileOrPhone() {
        let rawText = [
            "Lee Consulting",
            "Fax: +1 212 555 0102"
        ].joined(separator: "\n")

        let result = BusinessCardFieldParser.parse(rawText: rawText)

        XCTAssertEqual(result.company, "Lee Consulting")
        XCTAssertNil(result.name)
        XCTAssertNil(result.mobile, "Fax 不能被兜底成 Mobile")
        XCTAssertNil(result.phone, "Fax 不能被兜底成 Office phone")
        XCTAssertNil(result.email)
        XCTAssertNil(result.website)
        XCTAssertNil(result.address)
    }

    // MARK: - 4. 人名 vs 公司名

    func testPersonNameAndCompanyName_areDisambiguated() {
        let variants = [
            [
                "Jordan Lee",
                "Lee Consulting",
                "Senior Manager",
                "Mobile: +1 212 555 0100"
            ],
            [
                "Lee Consulting",
                "Jordan Lee",
                "Senior Manager",
                "Mobile: +1 212 555 0100"
            ]
        ]

        for lines in variants {
            let result = BusinessCardFieldParser.parse(rawText: lines.joined(separator: "\n"))
            XCTAssertEqual(result.name, "Jordan Lee", "Lee 是姓，但不能把 Lee Consulting 当人名")
            XCTAssertEqual(result.company, "Lee Consulting", "Consulting 后缀说明这是公司名")
            XCTAssertEqual(result.jobTitle, "Senior Manager")
            XCTAssertEqual(result.mobile, "+12125550100")
        }
    }

    func testCompanyOnlyCard_doesNotInventPersonName() {
        let result = BusinessCardFieldParser.parse(
            rawText: [
                "Lee Consulting",
                "Mobile: +1 212 555 0100",
                "hello@leeconsulting.example"
            ].joined(separator: "\n")
        )

        XCTAssertNil(result.name, "只有公司名时不得把公司名当作人名")
        XCTAssertEqual(result.company, "Lee Consulting")
        XCTAssertEqual(result.mobile, "+12125550100")
        XCTAssertNil(result.website, "邮箱域名不是网址")
    }

    // MARK: - 5. 严格宁缺毋滥：稀疏名片

    func testSparseCard_doesNotFabricateFields() {
        let rawText = [
            "Alex Turner",
            "alex.turner@example.com"
        ].joined(separator: "\n")

        let result = BusinessCardFieldParser.parse(rawText: rawText)

        XCTAssertEqual(result.name, "Alex Turner")
        XCTAssertEqual(result.email, "alex.turner@example.com")
        XCTAssertNil(result.company)
        XCTAssertNil(result.jobTitle)
        XCTAssertNil(result.mobile)
        XCTAssertNil(result.phone)
        XCTAssertNil(result.website, "仅有邮箱时不得凭空补出 Website")
        XCTAssertNil(result.address)
        XCTAssertEqual(result.rawText, rawText)
    }

    // MARK: - 6. 单行 · 分隔 + 无网址

    func testSingleLineSeparatedCard_handlesAmpersandCompanyAndNilWebsite() {
        let rawText = "Fold & Field · Alex Turner · Founder · alex@example.com · +44 7700 900123 · Unit 7, Tileyard Road, London N7 9AH"

        let result = BusinessCardFieldParser.parse(rawText: rawText)

        XCTAssertEqual(result.company, "Fold & Field")
        XCTAssertEqual(result.name, "Alex Turner")
        XCTAssertEqual(result.jobTitle, "Founder")
        XCTAssertEqual(result.email, "alex@example.com")
        XCTAssertEqual(result.mobile, "+447700900123")
        XCTAssertNil(result.phone)
        XCTAssertNil(result.website)
        XCTAssertEqual(result.address, "Unit 7, Tileyard Road, London N7 9AH")
    }

    // MARK: - 7. 竖排 CJK + 公司名含职位词

    func testVerticalCJK_companyContainingLawyerWord_doesNotBecomeJobTitle() {
        let rawText = [
            "明 道 律 师 事 务 所",
            "顾 清 和",
            "执 业 律 师",
            "Attorney at Law",
            "M 135 0000 8888",
            "T 025-0000 9999",
            "F 025-0000 1010",
            "gu.qinghe@example.com",
            "南京市鼓楼区中山路 0000 号 国际大厦 26 层"
        ].joined(separator: "\n")

        let result = BusinessCardFieldParser.parse(rawText: rawText)

        XCTAssertEqual(result.name, "顾清和")
        XCTAssertEqual(result.company, "明道律师事务所")
        XCTAssertEqual(result.jobTitle, "执业律师 / Attorney at Law")
        XCTAssertEqual(result.mobile, "13500008888")
        XCTAssertEqual(result.phone, "02500009999")
        XCTAssertNotEqual(result.phone, "02500001010", "Fax 不得进入 phone")
        XCTAssertNil(result.website)
        XCTAssertEqual(result.address, "南京市鼓楼区中山路 0000 号 国际大厦 26 层")
    }

    // MARK: - 8. 大学后缀 + 中文职称 + 无「路/街」地址

    func testUniversityCompanyAndProfessorTitle_areExtracted() {
        let rawText = [
            "清华大学",
            "李明",
            "教授",
            "Tel: 010-12345678",
            "北京市海淀区清华园 1 号"
        ].joined(separator: "\n")

        let result = BusinessCardFieldParser.parse(rawText: rawText)

        XCTAssertEqual(result.name, "李明")
        XCTAssertEqual(result.company, "清华大学")
        XCTAssertEqual(result.jobTitle, "教授")
        XCTAssertNil(result.mobile)
        XCTAssertEqual(result.phone, "01012345678")
        XCTAssertNil(result.email)
        XCTAssertNil(result.website)
        XCTAssertEqual(result.address, "北京市海淀区清华园 1 号")
    }

    // MARK: - 9. 多行地址 + 中英双语职位

    func testMultilineAddress_andBilingualTitle_areNormalized() {
        let rawText = [
            "森屿生活",
            "白露 Bai Lu",
            "品牌主理人 Brand Director",
            "M 136 0000 4242",
            "T 0571-0000 4343",
            "bai.lu@example.com",
            "www.example.com/senyu",
            "浙江省杭州市西湖区文三路 0000 号",
            "创意大厦 A 座 12 楼 1208 室"
        ].joined(separator: "\n")

        let result = BusinessCardFieldParser.parse(rawText: rawText)

        XCTAssertEqual(result.name, "白露 Bai Lu")
        XCTAssertEqual(result.company, "森屿生活")
        XCTAssertEqual(result.jobTitle, "品牌主理人 / Brand Director")
        XCTAssertEqual(result.mobile, "13600004242")
        XCTAssertEqual(result.phone, "057100004343")
        XCTAssertEqual(result.website, "https://www.example.com/senyu")
        XCTAssertEqual(
            result.address,
            "浙江省杭州市西湖区文三路 0000 号创意大厦 A 座 12 楼 1208 室",
            "中文多行地址应直接拼接，不插入英文逗号"
        )
    }
}
