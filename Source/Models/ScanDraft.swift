//
//  ScanDraft.swift
//  CamCardClone
//
//  扫描流水线 → 校对页之间传递的临时草稿。
//
//  草稿只存在于内存中（不含数据库主键、不写 SwiftData），
//  用户在人工校对页点击「确认保存」后才会落盘。
//

import Foundation
import UIKit

// MARK: - 解析结果

/// 8 个核心字段的纯值结果，与 CamCardCore 的解析器解耦。
struct ParsedCardFields: Equatable, Sendable {
    var name: String?
    var company: String?
    var jobTitle: String?
    var mobile: String?
    var phone: String?
    var email: String?
    var website: String?
    var address: String?
}

// MARK: - 扫描阶段

/// 扫描流水线的可观察阶段，用于取景页的进度文案。
enum CardScanStage: String, CaseIterable, Identifiable {
    case detecting
    case correcting
    case recognizing
    case extracting
    case ready

    var id: String { rawValue }

    var title: String {
        switch self {
        case .detecting: return "正在检测名片边缘"
        case .correcting: return "正在校正透视"
        case .recognizing: return "正在识别文字"
        case .extracting: return "正在提取字段"
        case .ready: return "识别完成"
        }
    }

    var systemImage: String {
        switch self {
        case .detecting: return "viewfinder"
        case .correcting: return "perspective"
        case .recognizing: return "text.viewfinder"
        case .extracting: return "wand.and.stars"
        case .ready: return "checkmark.circle"
        }
    }

    var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

// MARK: - 草稿

/// 一次扫描的完整结果：原图、校正图、OCR 原文、置信度与解析字段。
struct ScanDraft: Identifiable {
    let id: UUID
    let originalImage: UIImage
    let processedImage: UIImage?
    let rawText: String
    let confidence: Float
    let didDetectCardBoundary: Bool
    let source: CardSource
    let parsed: ParsedCardFields
    let warnings: [String]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        originalImage: UIImage,
        processedImage: UIImage?,
        rawText: String,
        confidence: Float,
        didDetectCardBoundary: Bool,
        source: CardSource,
        parsed: ParsedCardFields,
        warnings: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.originalImage = originalImage
        self.processedImage = processedImage
        self.rawText = rawText
        self.confidence = confidence
        self.didDetectCardBoundary = didDetectCardBoundary
        self.source = source
        self.parsed = parsed
        self.warnings = warnings
        self.createdAt = createdAt
    }

    var fields: CardFormValues {
        CardFormValues(parsed: parsed)
    }

    /// 展示用图片：优先校正图；检测失败时回退原图。
    var displayImage: UIImage {
        processedImage ?? originalImage
    }

    var hasDistinctProcessedImage: Bool {
        guard let processedImage else { return false }
        return processedImage !== originalImage
    }

    var confidenceDescription: String {
        if confidence <= 0 { return "未获得置信度" }
        return "识别置信度 \(Int((confidence * 100).rounded()))%"
    }

    var isLowConfidence: Bool {
        confidence > 0 && confidence < 0.6
    }
}
