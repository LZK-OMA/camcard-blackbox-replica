//
//  CardCorrectionViewModel.swift
//  CamCardClone
//
//  Human-in-the-Loop 校对页 ViewModel。
//
//  规则：
//  - 布局与保存逻辑复用同一套，同时服务「扫描新建」与「详情编辑」；
//  - 保存前必须通过 name/company 必填校验；
//  - 新建时若命中手机号或姓名+公司重复，先提示用户二次确认；
//  - 保存成功后才由 View 决定 dismiss / 回调。
//

import Foundation
import Observation
import UIKit

// MARK: - 模式

enum CardCorrectionMode {
    case create(ScanDraft)
    case edit(BusinessCard)

    var isCreate: Bool {
        if case .create = self { return true }
        return false
    }

    var isEdit: Bool {
        if case .edit = self { return true }
        return false
    }

    var title: String {
        isCreate ? "校对名片" : "编辑名片"
    }

    var saveButtonTitle: String {
        isCreate ? "确认保存" : "保存修改"
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class CardCorrectionViewModel {

    // MARK: 输出

    var values: CardFormValues
    private(set) var isSaving = false
    var errorMessage: String?
    var showDuplicateWarning = false

    /// 图片在「创建」模式下来自扫描草稿；「编辑」模式下按需异步加载，
    /// 因此必须可写。UI 只读。
    private(set) var originalImage: UIImage?
    private(set) var processedImage: UIImage?
    /// 手动四角校正后重新生成的校正图（优先于自动校正图展示与保存）。
    private(set) var manuallyCorrectedImage: UIImage?
    /// 是否使用过手动四角校正（用于文案与保存）。
    private(set) var wasManuallyCorrected = false
    /// 编辑模式异步加载图片时的 loading 状态，供 UI 展示占位进度。
    private(set) var isLoadingImages = false

    let rawText: String
    let confidence: Float
    private(set) var warnings: [String]
    private(set) var didDetectCardBoundary: Bool
    let source: CardSource

    // MARK: 依赖

    let mode: CardCorrectionMode
    private let store: CardStore
    private let initialValues: CardFormValues

    /// 编辑模式下用于后台异步读取图片的相对路径。
    private let originalImagePath: String?
    private let processedImagePath: String?
    @ObservationIgnored private var didLoadEditImages = false
    /// 防止 `.task` 在页面反复出现时并发重复解码；与 UI 的 isLoadingImages 分离，
    /// 因为编辑模式初始就需要展示 loading 占位。
    @ObservationIgnored private var isEditImageLoadInFlight = false

    init(mode: CardCorrectionMode, store: CardStore) {
        self.mode = mode
        self.store = store

        switch mode {
        case .create(let draft):
            self.values = draft.fields
            self.initialValues = draft.fields
            self.originalImage = draft.originalImage
            self.processedImage = draft.processedImage
            self.originalImagePath = nil
            self.processedImagePath = nil
            self.rawText = draft.rawText
            self.confidence = draft.confidence
            self.warnings = draft.warnings
            self.didDetectCardBoundary = draft.didDetectCardBoundary
            self.source = draft.source

        case .edit(let card):
            let form = CardFormValues(card: card)
            self.values = form
            self.initialValues = form

            // 不在 init（主线程）里同步解码大图：先记录相对路径，
            // 由 View 的 .task 调用 loadImagesIfNeeded() 在后台解码。
            self.originalImage = nil
            self.processedImage = nil
            self.originalImagePath = card.originalImageFilename
            self.processedImagePath = card.processedImageFilename
            // 首帧就展示 loading 占位，避免先闪一下「图片不可用」。
            self.isLoadingImages = true

            self.rawText = ""
            self.confidence = 1
            self.warnings = []
            self.didDetectCardBoundary = card.processedImageFilename != nil
            self.source = card.source
        }
    }

    // MARK: - 图片加载

    /// 编辑模式下按需异步加载原图 / 校正图。
    /// 解码与缩略图生成由 `CardImageLoader` 在后台队列完成，主线程只接收结果。
    func loadImagesIfNeeded() async {
        guard mode.isEdit, !didLoadEditImages, !isEditImageLoadInFlight else { return }
        guard let originalImagePath else { return }

        isEditImageLoadInFlight = true
        isLoadingImages = true
        defer {
            isEditImageLoadInFlight = false
            isLoadingImages = false
        }

        let manager = store.imageFileManager
        let original = await CardImageLoader.shared.image(
            relativePath: originalImagePath,
            using: manager,
            maxPixelSize: 1800
        )
        guard !Task.isCancelled else { return }

        var processed: UIImage?
        if let processedImagePath {
            processed = await CardImageLoader.shared.image(
                relativePath: processedImagePath,
                using: manager,
                maxPixelSize: 1800
            )
            guard !Task.isCancelled else { return }
        }

        self.originalImage = original
        self.processedImage = processed
        // 只有完整加载成功后才标记完成；任务被取消时保留重试机会。
        didLoadEditImages = true
    }

    // MARK: - 展示

    var hasDistinctProcessedImage: Bool {
        if let manuallyCorrectedImage {
            return manuallyCorrectedImage !== originalImage
        }
        guard let processedImage else { return false }
        return processedImage !== originalImage
    }

    var displayImage: UIImage? {
        manuallyCorrectedImage ?? processedImage ?? originalImage
    }

    var confidenceDescription: String {
        guard mode.isCreate else { return "人工编辑" }
        guard confidence > 0, confidence <= 1 else { return "人工录入" }
        return "整体识别置信度 \(Int((confidence * 100).rounded()))%"
    }

    var isLowConfidence: Bool {
        confidence > 0 && confidence < 0.6
    }

    var sourceDescription: String {
        switch source {
        case .camera: return "相机扫描"
        case .photoLibrary: return "相册导入"
        case .file: return "文件导入"
        case .manual: return "手动录入"
        }
    }

    var hasUnsavedChanges: Bool {
        values != initialValues
    }

    var filledFieldCount: Int {
        values.filledFieldCount
    }

    var validationMessage: String? {
        values.validationError
    }

    /// 低置信时优先聚焦第一个空字段，其次是姓名。
    var preferredFocusField: CardFormField? {
        if let firstEmpty = CardFormField.allCases.first(where: {
            values.trimmedValue(for: $0) == nil
        }) {
            return firstEmpty
        }
        return .name
    }

    /// 保存时使用的草稿：把手动校正图替换进 processedImage，其余字段保持原样。
    private var draftForSaving: ScanDraft {
        guard case .create(let draft) = mode else {
            preconditionFailure("仅新建模式会使用 draftForSaving")
        }
        guard let manuallyCorrectedImage,
              manuallyCorrectedImage !== draft.processedImage else {
            return draft
        }
        return ScanDraft(
            id: draft.id,
            originalImage: draft.originalImage,
            processedImage: manuallyCorrectedImage,
            rawText: draft.rawText,
            confidence: draft.confidence,
            didDetectCardBoundary: true,
            source: draft.source,
            parsed: draft.parsed,
            warnings: warnings,
            createdAt: draft.createdAt
        )
    }

    // MARK: - 手动四角校正

    /// 应用手动四角校正的结果：只替换「校正图」，不改动 OCR 原文与已识别字段。
    /// 保存时会把这张图写入沙盒（见 `draftForSaving`）。
    func applyManualCorrection(_ image: UIImage) {
        manuallyCorrectedImage = image
        wasManuallyCorrected = true
        didDetectCardBoundary = true
        // 手动校正后，「未检测到边缘」的提示不再成立。
        warnings.removeAll { $0.contains("未检测到清晰的名片边缘") }
        errorMessage = nil
    }

    /// 是否允许手动调整边角：只有「扫描新建」模式才有扫描流水线可用。
    var canManuallyAdjustCorners: Bool {
        mode.isCreate && originalImage != nil
    }

    // MARK: - 保存

    func save(force: Bool = false) async -> BusinessCard? {
        guard !isSaving else { return nil }

        if let error = values.validationError {
            errorMessage = error
            return nil
        }

        if mode.isCreate,
           !force,
           store.hasPotentialDuplicate(for: values) {
            showDuplicateWarning = true
            return nil
        }

        isSaving = true
        errorMessage = nil
        // 所有退出路径（成功 / 抛错 / 取消）都在 MainActor 上同步复位，
        // 保证「保存中…」不会把保存与取消按钮永久禁用。
        defer {
            isSaving = false
        }

        do {
            switch mode {
            case .create:
                // 图片落盘在后台队列执行，await 返回后仍由 @MainActor 写库并刷新列表。
                // 若用户做过手动四角校正，draftForSaving 会带上新的校正图。
                let card = try await store.createCard(from: draftForSaving, values: values)
                showDuplicateWarning = false
                return card
            case .edit(let card):
                try store.updateCard(card, with: values)
                showDuplicateWarning = false
                return card
            }
        } catch {
            showDuplicateWarning = false
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func clear(_ field: CardFormField) {
        values[field] = ""
    }

    func dismissDuplicateWarning() {
        showDuplicateWarning = false
    }

    func confirmDuplicateSave() async -> BusinessCard? {
        showDuplicateWarning = false
        return await save(force: true)
    }
}
