//
//  ReferenceSuiteHeadlessTests.swift
//  CamCardClone
//
//  T01–T20 Reference Test Suite 的无头部分（macOS / SwiftPM，不依赖模拟器 UI）。
//
//  覆盖：
//  - T04 拍摄进入识别流程（无相机时的等价路径：CameraSource == .camera）
//  - T05 相册导入进入识别流程（CameraSource == .photoLibrary）
//  - T06 名片边界检测（检测成功 / 降级 / 手动四角兜底）
//  - T07 OCR 产生原始文本
//  - T08 结构化字段抽取（与 Ground Truth 对照）
//  - T09 缺失字段不得虚构
//  - T10 多电话（Mobile / Office / Fax）字段处理
//  - T11 人工校正后保存修改结果
//  - T19 vCard 导出字段映射
//
//  说明：T01/T02/T03/T12/T13/T14/T15/T16/T17/T18/T20 的 UI 部分见
//  CamCardAppUITests/ReferenceSuiteUITests.swift。
//

import XCTest
import SwiftData
import UIKit

@testable import CamCardAppCore
@testable import CamCardCore

/// 默认 OCR 夹具（T04/T05/T07 共用）。
private let defaultOCRLines: [OCRTextLine] = [
    OCRTextLine(text: "星澜科技（深圳）有限公司", confidence: 0.96, boundingBox: .init(x: 0.1, y: 0.82, width: 0.8, height: 0.06)),
    OCRTextLine(text: "产品总监  陈亦舟", confidence: 0.94, boundingBox: .init(x: 0.1, y: 0.7, width: 0.8, height: 0.06)),
    OCRTextLine(text: "Mobile 138 0000 1234", confidence: 0.95, boundingBox: .init(x: 0.1, y: 0.56, width: 0.8, height: 0.06)),
    OCRTextLine(text: "E-mail: Chen.Yizhou@Example.com", confidence: 0.93, boundingBox: .init(x: 0.1, y: 0.44, width: 0.8, height: 0.06))
]

@MainActor
final class ReferenceSuiteHeadlessTests: XCTestCase {

    // MARK: - 夹具

    private var tempRoot: URL!
    private var container: ModelContainer!
    private var imageManager: CardImageFileManager!
    private var store: CardStore!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceSuiteHeadlessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        container = try CardRepository.makeInMemoryContainer()
        imageManager = CardImageFileManager(baseDirectory: tempRoot)
        let repository = CardRepository(
            context: container.mainContext,
            imageFileManager: imageManager
        )
        store = CardStore(repository: repository, imageFileManager: imageManager)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        container = nil
        store = nil
    }

    // MARK: - 工具

    private func makeMockPipeline(
        detected: Bool,
        ocrLines: [OCRTextLine] = defaultOCRLines,
        failingOCR: Bool = false
    ) -> CardScanPipeline {
        CardScanPipeline(
            recognizer: MockTextRecognizer(lines: ocrLines, failing: failingOCR),
            corrector: MockRectangleCorrector(detected: detected)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func loadGroundTruth() throws -> [GroundTruthSample] {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "ground_truth",
                withExtension: "json",
                subdirectory: "Fixtures"
            ),
            "缺少 ground_truth.json 夹具"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([GroundTruthSample].self, from: data)
    }

    private func sample(_ id: String, in samples: [GroundTruthSample]) throws -> GroundTruthSample {
        try XCTUnwrap(samples.first { $0.id == id }, "缺少测试样例 \(id)")
    }

    // MARK: - T04 拍摄 → 识别流程

    func test_T04_captureImage_entersRecognitionFlow() async throws {
        let viewModel = CardScannerViewModel(pipeline: makeMockPipeline(detected: true))
        let image = makePackageTestImage()

        viewModel.process(image: image, source: .camera)

        let entered = await waitUntil { viewModel.reviewPresented }
        XCTAssertTrue(entered, "❌ T04：拍摄图片后没有进入校对/识别流程")
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertEqual(viewModel.draft?.source, .camera)
        XCTAssertEqual(viewModel.stage, .ready)
    }

    // MARK: - T05 相册导入 → 识别流程

    func test_T05_photoLibraryImage_entersRecognitionFlow() async throws {
        let viewModel = CardScannerViewModel(pipeline: makeMockPipeline(detected: true))
        let image = makePackageTestImage()

        viewModel.process(image: image, source: .photoLibrary)

        let entered = await waitUntil { viewModel.reviewPresented }
        XCTAssertTrue(entered, "❌ T05：相册导入后没有进入识别流程")
        XCTAssertEqual(viewModel.draft?.source, .photoLibrary)
        XCTAssertFalse((viewModel.draft?.rawText ?? "").isEmpty, "导入后应产生 OCR 原始文本")
    }

    // MARK: - T06 名片边界检测 / 降级 / 手动四角

    func test_T06_boundaryDetection_success_fallback_and_manualQuad() async throws {
        let image = makePackageTestImage()

        // 1) 检测成功：产出校正图且 draft 标记为已检测。
        let detectedPipeline = makeMockPipeline(detected: true)
        let detectedOutcome = await detectedPipeline.correct(image)
        XCTAssertTrue(detectedOutcome.didDetectCardBoundary)
        XCTAssertFalse(detectedOutcome.processedImage === image, "检测成功时应产出独立的校正图")
        XCTAssertNotNil(detectedOutcome.detectedQuad)

        // 2) 检测失败：降级为原图，且不产生「已校正」标记。
        let failedPipeline = makeMockPipeline(detected: false)
        let failedOutcome = await failedPipeline.correct(image)
        XCTAssertFalse(failedOutcome.didDetectCardBoundary)
        XCTAssertTrue(failedOutcome.processedImage === image, "检测失败应降级使用原图")

        // 3) 手动四角兜底：用有效四角重新做透视校正。
        let manualOutcome = await detectedPipeline.correctWithManualQuad(
            image,
            quad: ManualCardQuad(
                topLeft: CGPoint(x: 0.10, y: 0.12),
                topRight: CGPoint(x: 0.90, y: 0.10),
                bottomRight: CGPoint(x: 0.92, y: 0.88),
                bottomLeft: CGPoint(x: 0.08, y: 0.90)
            )
        )
        XCTAssertTrue(manualOutcome.didDetectCardBoundary, "手动四角应生成校正结果")
        XCTAssertNotNil(manualOutcome.processedImage.cgImage)
        let topLeftX = try XCTUnwrap(manualOutcome.detectedQuad?.topLeft.x)
        XCTAssertEqual(topLeftX, 0.10, accuracy: 0.0001)
    }

    // MARK: - T07 OCR 原始文本

    func test_T07_ocr_producesRawText() async throws {
        let viewModel = CardScannerViewModel(pipeline: makeMockPipeline(detected: true))
        viewModel.process(image: makePackageTestImage(), source: .camera)

        _ = await waitUntil { viewModel.draft != nil }
        let draft = try XCTUnwrap(viewModel.draft)

        XCTAssertTrue(draft.rawText.contains("星澜科技（深圳）有限公司"))
        XCTAssertTrue(draft.rawText.contains("Mobile 138 0000 1234"))
        XCTAssertGreaterThan(draft.confidence, 0.9)
    }

    // MARK: - T08 结构化字段抽取

    func test_T08_structuredExtraction_matchesGroundTruth() throws {
        let samples = try loadGroundTruth()

        for id in ["TC01", "TC04", "TC05"] {
            let sample = try sample(id, in: samples)
            let parsed = CardFieldParserBridge.parse(sample.raw_text)
            let expected = sample.ground_truth

            XCTAssertEqual(parsed.name, expected.name, "\(id) name")
            XCTAssertEqual(parsed.company, expected.company, "\(id) company")
            XCTAssertEqual(parsed.jobTitle, expected.jobTitle, "\(id) jobTitle")
            XCTAssertEqual(parsed.mobile, expected.mobile, "\(id) mobile")
            XCTAssertEqual(parsed.phone, expected.phone, "\(id) phone")
            XCTAssertEqual(parsed.email, expected.email, "\(id) email")
            XCTAssertEqual(parsed.website, expected.website, "\(id) website")
            XCTAssertEqual(parsed.address, expected.address, "\(id) address")
        }
    }

    // MARK: - T09 缺失字段不得虚构

    func test_T09_missingFields_areNil_notFabricated() throws {
        let samples = try loadGroundTruth()

        let tc02 = try sample("TC02", in: samples)
        let parsed02 = CardFieldParserBridge.parse(tc02.raw_text)
        XCTAssertNil(parsed02.email, "❌ T09：名片没有邮箱时不得虚构 Email")
        XCTAssertNil(parsed02.website, "❌ T09：名片没有网址时不得虚构 Website")

        let tc03 = try sample("TC03", in: samples)
        let parsed03 = CardFieldParserBridge.parse(tc03.raw_text)
        XCTAssertNil(parsed03.website, "❌ T09：名片没有网址时不得虚构 Website")
        XCTAssertNotNil(parsed03.email)
    }

    // MARK: - T10 多电话（手机 / 座机 / 传真）

    func test_T10_multiplePhones_areClassifiedCorrectly() throws {
        let samples = try loadGroundTruth()
        let tc04 = try sample("TC04", in: samples)
        let parsed = CardFieldParserBridge.parse(tc04.raw_text)

        XCTAssertEqual(parsed.mobile, tc04.ground_truth.mobile, "手机号应归入 mobile")
        XCTAssertEqual(parsed.phone, tc04.ground_truth.phone, "座机应归入 phone")

        // 传真不得混入手机 / 座机（当前结果模型不含 fax 字段，要求不回填到 phone/mobile）。
        let fax = try XCTUnwrap(tc04.ground_truth.fax)
        let faxDigits = fax.filter(\.isNumber)
        XCTAssertFalse((parsed.phone ?? "").contains(faxDigits), "❌ T10：传真混入了办公电话")
        XCTAssertFalse((parsed.mobile ?? "").contains(faxDigits), "❌ T10：传真混入了手机")

        // 手机号也不得混入座机。
        XCTAssertNotEqual(parsed.mobile, parsed.phone)
    }

    // MARK: - T11 人工校正后保存

    func test_T11_manualCorrection_savesEditedValues() async throws {
        let samples = try loadGroundTruth()
        let tc01 = try sample("TC01", in: samples)
        let parsed = CardFieldParserBridge.parse(tc01.raw_text)

        let draft = ScanDraft(
            originalImage: makePackageTestImage(),
            processedImage: makePackageTestImage(width: 900, height: 560),
            rawText: tc01.raw_text,
            confidence: 0.94,
            didDetectCardBoundary: true,
            source: .camera,
            parsed: parsed,
            warnings: []
        )

        let viewModel = CardCorrectionViewModel(mode: .create(draft), store: store)
        viewModel.values.name = "手动修改姓名"
        viewModel.values.company = "手动修改公司"
        viewModel.values.mobile = "13900001111"

        let card = await viewModel.save()
        let saved = try XCTUnwrap(card, "❌ T11：人工校正后的保存失败")

        XCTAssertEqual(saved.name, "手动修改姓名")
        XCTAssertEqual(saved.company, "手动修改公司")
        XCTAssertEqual(saved.mobile, "13900001111")
        XCTAssertEqual(store.cards.count, 1)

        // 图片已落盘，且数据库保存的是相对路径。
        XCTAssertFalse(saved.originalImageFilename.isEmpty)
        let imageURL = try XCTUnwrap(store.imageFileManager.imageURL(for: saved.originalImageFilename))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path), "保存后原图应已落盘")
    }

    // MARK: - T19 vCard 导出字段映射

    func test_T19_vCard_mapsAllFields() throws {
        let card = BusinessCard(
            name: "陈亦舟",
            company: "星澜科技（深圳）有限公司",
            jobTitle: "产品总监",
            mobile: "13800001234",
            phone: "075500005678",
            fax: "075500009999",
            email: "Chen.Yizhou@Example.com",
            website: "www.example.com",
            address: "深圳市南山区科苑南路 0000 号 8 栋 1201",
            tags: ["客户", "展会"],
            notes: "2026 移动计算大会",
            originalImageFilename: "fixture/original.heic"
        )
        card.sanitize()

        let vcard = ContactExporter().vCard(for: card)

        XCTAssertTrue(vcard.hasPrefix("BEGIN:VCARD\r\n"))
        XCTAssertTrue(vcard.contains("VERSION:3.0"))
        XCTAssertTrue(vcard.contains("FN:陈亦舟"), "vCard 缺少姓名映射")
        XCTAssertTrue(vcard.contains("ORG:星澜科技（深圳）有限公司"), "vCard 缺少公司映射")
        XCTAssertTrue(vcard.contains("TITLE:产品总监"), "vCard 缺少职位映射")
        XCTAssertTrue(vcard.contains("TEL;TYPE=CELL:13800001234"), "vCard 缺少手机映射")
        XCTAssertTrue(vcard.contains("TEL;TYPE=WORK,VOICE:075500005678"), "vCard 缺少办公电话映射")
        XCTAssertTrue(vcard.contains("TEL;TYPE=WORK,FAX:075500009999"), "vCard 缺少传真映射")
        XCTAssertTrue(vcard.contains("EMAIL;TYPE=INTERNET:chen.yizhou@example.com"), "vCard 缺少邮箱映射")
        XCTAssertTrue(vcard.contains("URL:https://www.example.com"), "vCard 缺少网址映射")
        XCTAssertTrue(vcard.contains("ADR;TYPE=WORK:"), "vCard 缺少地址映射")
        XCTAssertTrue(vcard.contains("NOTE:2026 移动计算大会"), "vCard 缺少备注映射")
        XCTAssertTrue(vcard.contains("CATEGORIES:客户,展会"), "vCard 缺少标签映射")
        XCTAssertTrue(vcard.contains("UID:\(card.id.uuidString)"))
        XCTAssertTrue(vcard.hasSuffix("END:VCARD\r\n"))
    }
}

// MARK: - 测试替身

private struct MockTextRecognizer: CardTextRecognizing {

    let lines: [OCRTextLine]
    let failing: Bool

    func recognizeText(in image: UIImage) async throws -> OCRResult {
        if failing {
            throw CardScanError.invalidImage
        }
        let mean = lines.isEmpty
            ? 0
            : lines.reduce(Float(0)) { $0 + $1.confidence } / Float(lines.count)
        return OCRResult(lines: lines, meanConfidence: mean)
    }
}

private struct MockRectangleCorrector: CardRectangleCorrecting {

    let detected: Bool

    func correct(_ image: UIImage) async -> CardCorrectionOutcome {
        if detected {
            return CardCorrectionOutcome(
                originalImage: image,
                processedImage: makePackageTestImage(width: 900, height: 560),
                didDetectCardBoundary: true,
                detectionConfidence: 0.9,
                detectedQuad: .cardDefault
            )
        }
        return CardCorrectionOutcome(
            originalImage: image,
            processedImage: image,
            didDetectCardBoundary: false,
            detectionConfidence: 0
        )
    }
}

// MARK: - Ground Truth 夹具模型

private struct GroundTruthSample: Decodable {
    let id: String
    let scenario: String
    let raw_text: String
    let ground_truth: GroundTruthFields
}

private struct GroundTruthFields: Decodable {
    let name: String?
    let company: String?
    let jobTitle: String?
    let mobile: String?
    let phone: String?
    let fax: String?
    let email: String?
    let website: String?
    let address: String?
}
