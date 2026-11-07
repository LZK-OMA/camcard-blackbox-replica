//
//  CardScanPipeline.swift
//  CamCardClone
//
//  本地图像流水线：区域检测 → 透视校正 → Vision OCR → 规则字段抽取。
//
//  设计要点：
//  - 所有重型工作（UIImage 方向归一化、Vision 请求、CIContext 渲染）都在
//    `Task.detached` 中执行，主线程只负责状态推进；
//  - 检测不到四边形时降级为原图，不阻断 OCR 与人工校对；
//  - OCR 结果按「从上到下、从左到右」排序后交给 BusinessCardFieldParser；
//  - 不发起任何网络请求。
//

@preconcurrency import CoreImage
import Foundation
import UIKit
import Vision

#if canImport(CamCardCore)
import CamCardCore
#endif

// MARK: - 值类型

struct OCRTextLine: Equatable, Sendable {
    let text: String
    /// 0...1
    let confidence: Float
    /// 归一化坐标，原点左下。
    let boundingBox: CGRect
}

struct OCRResult: Equatable, Sendable {
    let lines: [OCRTextLine]
    let meanConfidence: Float

    var rawText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    static let empty = OCRResult(lines: [], meanConfidence: 0)
}

struct CardCorrectionOutcome {
    let originalImage: UIImage
    let processedImage: UIImage
    let didDetectCardBoundary: Bool
    let detectionConfidence: Float
    /// 本次使用的四角（自动检测或手动指定），供「手动调整边角」初始化用。
    var detectedQuad: ManualCardQuad? = nil
}

// MARK: - 错误

enum CardScanError: LocalizedError {
    case invalidImage
    case recognitionFailed(Error)
    case correctionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "图片内容无效，请重新选择"
        case .recognitionFailed:
            return "文字识别失败，请重试或手动填写"
        case .correctionFailed:
            return "名片校正失败，请重试"
        }
    }

    var underlyingError: Error? {
        switch self {
        case .recognitionFailed(let error), .correctionFailed(let error):
            return error
        case .invalidImage:
            return nil
        }
    }
}

// MARK: - 协议

protocol CardTextRecognizing: Sendable {
    func recognizeText(in image: UIImage) async throws -> OCRResult
}

protocol CardRectangleCorrecting: Sendable {
    func correct(_ image: UIImage) async -> CardCorrectionOutcome
}

// MARK: - Vision OCR

struct VisionCardTextRecognizer: CardTextRecognizing {

    func recognizeText(in image: UIImage) async throws -> OCRResult {
        try await Task.detached(priority: .userInitiated) {
            let normalized = image.normalizedUpImage()
            guard let cgImage = normalized.cgImage else {
                throw CardScanError.invalidImage
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.008

            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: .up,
                options: [:]
            )

            do {
                try handler.perform([request])
            } catch {
                throw CardScanError.recognitionFailed(error)
            }

            let observations = (request.results ?? []).compactMap { observation -> OCRTextLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return OCRTextLine(
                    text: text,
                    confidence: candidate.confidence,
                    boundingBox: observation.boundingBox
                )
            }

            // Vision 的 boundingBox 原点在左下。多列排版时先按行（自上而下），
            // 同一行内再按 x（自左向右），避免把两列文本交叉拼接。
            let sorted = observations.sorted { lhs, rhs in
                let lhsTop = lhs.boundingBox.maxY
                let rhsTop = rhs.boundingBox.maxY
                let rowTolerance: CGFloat = 0.02

                if abs(lhsTop - rhsTop) > rowTolerance {
                    return lhsTop > rhsTop
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }

            let mean = sorted.isEmpty
                ? 0
                : sorted.reduce(Float(0)) { $0 + $1.confidence } / Float(sorted.count)

            return OCRResult(lines: sorted, meanConfidence: mean)
        }.value
    }
}

// MARK: - 透视校正

/// 透视校正器：把「归一化、左上角原点」的四角映射到 Core Image 坐标并执行
/// `CIPerspectiveCorrection`。自动检测与手动调整共用这一份实现。
enum CardPerspectiveCorrector {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// - Parameters:
    ///   - image: 已做方向归一化（orientation == .up）的图片
    ///   - quad: 归一化四角，原点左上（与 UI 一致）
    static func correctPerspective(image: UIImage, quad: ManualCardQuad) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        return correctPerspective(cgImage: cgImage, quad: quad)
    }

    static func correctPerspective(cgImage: CGImage, quad: ManualCardQuad) -> UIImage? {
        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        // UI 坐标（左上原点）→ Core Image 坐标（左下原点）
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(
                x: normalized.x * extent.width + extent.origin.x,
                y: (1 - normalized.y) * extent.height + extent.origin.y
            )
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            return nil
        }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: point(quad.topLeft)), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: point(quad.topRight)), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: point(quad.bottomRight)), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: point(quad.bottomLeft)), forKey: "inputBottomLeft")

        guard let output = filter.outputImage else { return nil }
        let outputExtent = output.extent.integral
        guard outputExtent.width >= 200,
              outputExtent.height >= 120,
              outputExtent.isInfinite == false else {
            return nil
        }

        guard let corrected = ciContext.createCGImage(output, from: outputExtent) else {
            return nil
        }
        return UIImage(cgImage: corrected)
    }
}

// MARK: - 区域检测 + 透视校正

struct VisionCardRectangleCorrector: CardRectangleCorrecting {

    func correct(_ image: UIImage) async -> CardCorrectionOutcome {
        await Task.detached(priority: .userInitiated) {
            let normalized = image.normalizedUpImage()

            guard let cgImage = normalized.cgImage else {
                return CardCorrectionOutcome(
                    originalImage: image,
                    processedImage: image,
                    didDetectCardBoundary: false,
                    detectionConfidence: 0
                )
            }

            guard let quad = Self.detectLargestRectangle(in: cgImage) else {
                return CardCorrectionOutcome(
                    originalImage: image,
                    processedImage: normalized,
                    didDetectCardBoundary: false,
                    detectionConfidence: 0
                )
            }

            // Vision 四角（归一化、左下原点）→ ManualCardQuad（归一化、左上原点）
            let manualQuad = Self.manualQuad(from: quad)

            guard let corrected = CardPerspectiveCorrector.correctPerspective(
                image: normalized,
                quad: manualQuad
            ) else {
                return CardCorrectionOutcome(
                    originalImage: image,
                    processedImage: normalized,
                    didDetectCardBoundary: true,
                    detectionConfidence: quad.confidence,
                    detectedQuad: manualQuad
                )
            }

            return CardCorrectionOutcome(
                originalImage: image,
                processedImage: corrected,
                didDetectCardBoundary: true,
                detectionConfidence: quad.confidence,
                detectedQuad: manualQuad
            )
        }.value
    }

    // MARK: 检测

    private struct Quad {
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomRight: CGPoint
        let bottomLeft: CGPoint
        let confidence: Float
    }

    private static func detectLargestRectangle(in cgImage: CGImage) -> Quad? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.55
        request.minimumAspectRatio = 0.15
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 30
        request.minimumSize = 0.2

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first else { return nil }

        // 面积过小的矩形通常是桌面纹理或卡片局部，直接放弃。
        let area = observation.boundingBox.width * observation.boundingBox.height
        guard area >= 0.12 else { return nil }

        return Quad(
            topLeft: observation.topLeft,
            topRight: observation.topRight,
            bottomRight: observation.bottomRight,
            bottomLeft: observation.bottomLeft,
            confidence: observation.confidence
        )
    }

    /// Vision 的归一化坐标原点在左下，这里翻转成 UI 的左上原点。
    private static func manualQuad(from quad: Quad) -> ManualCardQuad {
        ManualCardQuad(
            topLeft: CGPoint(x: quad.topLeft.x, y: 1 - quad.topLeft.y),
            topRight: CGPoint(x: quad.topRight.x, y: 1 - quad.topRight.y),
            bottomRight: CGPoint(x: quad.bottomRight.x, y: 1 - quad.bottomRight.y),
            bottomLeft: CGPoint(x: quad.bottomLeft.x, y: 1 - quad.bottomLeft.y)
        )
    }
}

// MARK: - 解析器桥接

enum CardFieldParserBridge {
    static func parse(_ rawText: String) -> ParsedCardFields {
        let result = BusinessCardFieldParser.parse(rawText: rawText)
        return ParsedCardFields(
            name: result.name,
            company: result.company,
            jobTitle: result.jobTitle,
            mobile: result.mobile,
            phone: result.phone,
            email: result.email,
            website: result.website,
            address: result.address
        )
    }
}

// MARK: - 流水线

struct CardScanPipeline {

    private let recognizer: any CardTextRecognizing
    private let corrector: any CardRectangleCorrecting

    init(
        recognizer: any CardTextRecognizing = VisionCardTextRecognizer(),
        corrector: any CardRectangleCorrecting = VisionCardRectangleCorrector()
    ) {
        self.recognizer = recognizer
        self.corrector = corrector
    }

    // MARK: 分步 API（便于取景页展示阶段进度）

    func correct(_ image: UIImage) async -> CardCorrectionOutcome {
        await corrector.correct(image)
    }

    /// 用用户手动指定的四角重新做透视校正。
    ///
    /// - 只重新生成校正图，不重新 OCR、不改动已识别的字段；
    /// - 编辑模式（mode == .edit）不支持手动校正，调用方会隐藏入口；
    /// - `quad` 为归一化坐标、原点左上（ManualCardQuad）。
    func correctWithManualQuad(
        _ image: UIImage,
        quad: ManualCardQuad
    ) async -> CardCorrectionOutcome {
        let validatedQuad = quad.clamped()

        return await Task.detached(priority: .userInitiated) {
            let normalized = image.normalizedUpImage()

            guard validatedQuad.isValid,
                  let corrected = CardPerspectiveCorrector.correctPerspective(
                      image: normalized,
                      quad: validatedQuad
                  ) else {
                return CardCorrectionOutcome(
                    originalImage: image,
                    processedImage: normalized,
                    didDetectCardBoundary: false,
                    detectionConfidence: 0,
                    detectedQuad: validatedQuad
                )
            }

            return CardCorrectionOutcome(
                originalImage: image,
                processedImage: corrected,
                didDetectCardBoundary: true,
                detectionConfidence: 1,
                detectedQuad: validatedQuad
            )
        }.value
    }

    func recognize(_ image: UIImage) async throws -> OCRResult {
        try await recognizer.recognizeText(in: image)
    }

    func extract(_ rawText: String) -> ParsedCardFields {
        CardFieldParserBridge.parse(rawText)
    }

    func makeDraft(
        originalImage: UIImage,
        outcome: CardCorrectionOutcome,
        ocr: OCRResult,
        fields: ParsedCardFields,
        source: CardSource
    ) -> ScanDraft {
        var warnings: [String] = []

        if !outcome.didDetectCardBoundary {
            warnings.append("未检测到清晰的名片边缘，已使用原图识别")
        }
        if ocr.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("未识别到文字，请手动填写字段")
        } else if ocr.meanConfidence > 0, ocr.meanConfidence < 0.6 {
            warnings.append("整体识别置信度较低，请逐项核对")
        }

        return ScanDraft(
            originalImage: originalImage,
            processedImage: outcome.processedImage,
            rawText: ocr.rawText,
            confidence: ocr.meanConfidence,
            didDetectCardBoundary: outcome.didDetectCardBoundary,
            source: source,
            parsed: fields,
            warnings: warnings
        )
    }

    /// 无文字 / OCR 失败时的兜底草稿：保留原图，字段全空，交给人工录入。
    func makeManualDraft(
        originalImage: UIImage,
        source: CardSource,
        reason: String?
    ) -> ScanDraft {
        var warnings = ["未能自动识别，请手动填写名片信息"]
        if let reason, !reason.isEmpty {
            warnings.append(reason)
        }
        return ScanDraft(
            originalImage: originalImage,
            processedImage: originalImage,
            rawText: "",
            confidence: 0,
            didDetectCardBoundary: false,
            source: source,
            parsed: ParsedCardFields(),
            warnings: warnings
        )
    }

    // MARK: 模拟拍摄

    /// 使用示例名片（TC01）走同一套规则解析器，保证演示结果与真实链路一致。
    func makeSimulatedDraft() -> ScanDraft {
        let capture = SampleCardFactory.makeCapture()
        let ocr = OCRResult(
            lines: capture.ocrLines,
            meanConfidence: 0.94
        )
        let fields = extract(capture.rawText)
        return ScanDraft(
            originalImage: capture.photo,
            processedImage: capture.croppedCard,
            rawText: capture.rawText,
            confidence: ocr.meanConfidence,
            didDetectCardBoundary: true,
            source: .camera,
            parsed: fields,
            warnings: []
        )
    }
}

// MARK: - UIImage 方向归一化

extension UIImage {
    /// 把 EXIF 方向烘焙进像素，确保 Vision / Core Image 使用同一套坐标系。
    /// 已经在 `.up` 的图片直接返回，避免无意义的重新渲染。
    func normalizedUpImage() -> UIImage {
        guard imageOrientation != .up else { return self }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = max(scale, 1)
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
