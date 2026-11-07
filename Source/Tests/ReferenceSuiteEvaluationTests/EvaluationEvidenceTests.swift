//
//  EvaluationEvidenceTests.swift
//  CamCardClone
//
//  30 张测试名片的证据采集（无头 / macOS）：
//  图片 → CardScanPipeline（Vision 区域检测 + 透视校正 + Vision OCR）→ 字段抽取
//  → 写出 Fixtures/Results/ocr_results.json，供 Scripts/evaluate.py 计算准确率。
//
//  运行：
//    swift test --disable-sandbox --filter EvaluationEvidenceTests
//  （需要完整磁盘访问权限以允许 Vision 框架工作）
//

import XCTest
import Foundation
import UIKit

@testable import CamCardAppCore
@testable import CamCardCore

final class EvaluationEvidenceTests: XCTestCase {

    // MARK: - 数据模型

    private struct GroundTruthSample: Decodable {
        let id: String
        let scenario: String
        let raw_text: String
    }

    private struct ResultsFile: Encodable {
        let generatedAt: String
        let environment: String
        let imageCount: Int
        let results: [CaseResult]
    }

    private struct BaselineFile: Encodable {
        let generatedAt: String
        let source: String
        let caseCount: Int
        let results: [BaselineResult]
    }

    private struct BaselineResult: Encodable {
        let id: String
        let scenario: String
        let fields: ParsedFields
    }

    private struct CaseResult: Encodable {
        let id: String
        let scenario: String
        let imagePath: String
        let ocrRawText: String
        let ocrLines: [OCRLine]
        let meanConfidence: Float
        let didDetectCardBoundary: Bool
        let detectionConfidence: Float
        let fields: ParsedFields
        let durationMilliseconds: Double
    }

    private struct OCRLine: Encodable {
        let text: String
        let confidence: Float
    }

    private struct ParsedFields: Encodable {
        let name: String?
        let company: String?
        let jobTitle: String?
        let mobile: String?
        let phone: String?
        let email: String?
        let website: String?
        let address: String?
    }

    // MARK: - 测试

    func testGenerateEvaluationResultsForAll30Cards() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReferenceSuiteEvaluationTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Source
            .deletingLastPathComponent()   // 仓库根目录

        let groundTruthURL = repoRoot.appendingPathComponent("ground_truth.json")
        let imagesDirectory = repoRoot.appendingPathComponent("Fixtures/Images", isDirectory: true)
        let resultsDirectory = repoRoot.appendingPathComponent("Fixtures/Results", isDirectory: true)
        try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        let samples = try decoder.decode(
            [GroundTruthSample].self,
            from: Data(contentsOf: groundTruthURL)
        )
        XCTAssertEqual(samples.count, 30, "Ground Truth 应包含 30 条样例")

        let pipeline = CardScanPipeline()
        var results: [CaseResult] = []
        var baselineResults: [BaselineResult] = []

        for sample in samples {
            let imageURL = imagesDirectory.appendingPathComponent("\(sample.id).png")
            guard let image = UIImage(contentsOfFile: imageURL.path) else {
                XCTFail("无法读取测试图片：\(imageURL.path)")
                continue
            }

            let start = Date()
            let outcome = await pipeline.correct(image)
            let ocr: OCRResult
            do {
                ocr = try await pipeline.recognize(outcome.processedImage)
            } catch {
                XCTFail("\(sample.id) OCR 失败：\(error)")
                continue
            }
            let fields = pipeline.extract(ocr.rawText)
            let duration = Date().timeIntervalSince(start) * 1000

            // 基线：直接用 Ground Truth 原文走同一套字段抽取（排除 OCR 影响）。
            let baselineFields = pipeline.extract(sample.raw_text)
            baselineResults.append(
                BaselineResult(
                    id: sample.id,
                    scenario: sample.scenario,
                    fields: ParsedFields(
                        name: baselineFields.name,
                        company: baselineFields.company,
                        jobTitle: baselineFields.jobTitle,
                        mobile: baselineFields.mobile,
                        phone: baselineFields.phone,
                        email: baselineFields.email,
                        website: baselineFields.website,
                        address: baselineFields.address
                    )
                )
            )

            results.append(
                CaseResult(
                    id: sample.id,
                    scenario: sample.scenario,
                    imagePath: "Fixtures/Images/\(sample.id).png",
                    ocrRawText: ocr.rawText,
                    ocrLines: ocr.lines.map { OCRLine(text: $0.text, confidence: $0.confidence) },
                    meanConfidence: ocr.meanConfidence,
                    didDetectCardBoundary: outcome.didDetectCardBoundary,
                    detectionConfidence: outcome.detectionConfidence,
                    fields: ParsedFields(
                        name: fields.name,
                        company: fields.company,
                        jobTitle: fields.jobTitle,
                        mobile: fields.mobile,
                        phone: fields.phone,
                        email: fields.email,
                        website: fields.website,
                        address: fields.address
                    ),
                    durationMilliseconds: (duration * 10).rounded() / 10
                )
            )
            print("✅ \(sample.id) \(sample.scenario) • \(Int(duration))ms • fields=\(fields.summaryForLog)")
        }

        XCTAssertEqual(results.count, 30, "应采集到 30 条评测结果")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let file = ResultsFile(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            environment: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            imageCount: results.count,
            results: results
        )
        let data = try encoder.encode(file)
        let outputURL = resultsDirectory.appendingPathComponent("ocr_results.json")
        try data.write(to: outputURL, options: .atomic)
        print("📄 评测结果已写入 \(outputURL.path)")

        let baselineFile = BaselineFile(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            source: "ground_truth.raw_text → CardFieldParserBridge",
            caseCount: baselineResults.count,
            results: baselineResults
        )
        let baselineData = try encoder.encode(baselineFile)
        let baselineURL = resultsDirectory.appendingPathComponent("parser_results.json")
        try baselineData.write(to: baselineURL, options: .atomic)
        print("📄 抽取基线已写入 \(baselineURL.path)")
    }
}

// MARK: - 日志辅助

private extension ParsedCardFields {
    var summaryForLog: String {
        var parts: [String] = []
        if let name { parts.append("name=\(name)") }
        if let company { parts.append("company=\(company)") }
        if let jobTitle { parts.append("title=\(jobTitle)") }
        if let mobile { parts.append("mobile=\(mobile)") }
        if let phone { parts.append("phone=\(phone)") }
        if let email { parts.append("email=\(email)") }
        if let website { parts.append("website=\(website)") }
        if let address { parts.append("address=\(address)") }
        return parts.joined(separator: ",")
    }
}
