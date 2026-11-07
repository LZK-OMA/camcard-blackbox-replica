//
//  CardCorrectionView.swift
//  CamCardClone
//
//  ★ 项目核心：Human-in-the-Loop 人工校对页。
//
//  上半部分：原图 / 校正大图，可全屏查看与切换；
//  下半部分：8 个核心字段的结构化编辑表单；
//  保存前：姓名或公司至少一个非空；新建时重复名片二次确认；
//  保存时：图片先落沙盒，再写 SwiftData，然后回到名片夹 / 关闭编辑页。
//

import SwiftUI
import UIKit

struct CardCorrectionView: View {

    // MARK: 依赖

    private let store: CardStore
    private let onSaved: ((BusinessCard) -> Void)?
    /// 扫描流水线：仅「扫描新建」模式传入，用于手动四角校正；编辑模式为 nil。
    private let pipeline: CardScanPipeline?
    /// 自动检测到的四角（作为手动校正编辑器的初始值）。
    private let initialQuad: ManualCardQuad?

    // MARK: 状态

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: CardCorrectionViewModel
    @FocusState private var focusedField: CardFormField?
    @State private var isShowingOriginal = false
    @State private var isShowingRawText = false
    @State private var isShowingRawTextSheet = false
    /// 全屏大图使用 item 驱动：图片与弹层同生共死，避免“条件内容为空 →
    /// 呈现一个无法关闭的空白 fullScreenCover”导致的永久遮挡。
    @State private var previewPayload: ImagePreviewPayload?
    /// 同一个视图只挂一个 alert，避免「放弃修改」/「可能重复添加」互相吞掉。
    @State private var activeAlert: CorrectionAlert?

    // MARK: - 手动四角校正

    /// 打开编辑器前在后台做方向归一化后的原图。
    @State private var quadEditorImage: UIImage?
    @State private var isShowingQuadEditor = false
    @State private var isPreparingQuadEditor = false
    @State private var isApplyingManualQuad = false

    // MARK: - 弹层模型

    private struct ImagePreviewPayload: Identifiable {
        let id = UUID()
        let image: UIImage
        let title: String
    }

    private enum CorrectionAlert: String, Identifiable {
        case discard
        case duplicate

        var id: String { rawValue }
    }

    init(
        mode: CardCorrectionMode,
        store: CardStore,
        pipeline: CardScanPipeline? = nil,
        initialQuad: ManualCardQuad? = nil,
        onSaved: ((BusinessCard) -> Void)? = nil
    ) {
        self.store = store
        self.onSaved = onSaved
        self.pipeline = pipeline
        self.initialQuad = initialQuad
        _viewModel = State(initialValue: CardCorrectionViewModel(mode: mode, store: store))
    }

    // MARK: - Body

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: 18) {
                imageSection

                if canManuallyAdjustCorners {
                    manualCornerEntry
                }

                if !viewModel.warnings.isEmpty {
                    warningsBanner
                }

                metadataRow
                fieldSection

                if !viewModel.rawText.isEmpty {
                    rawTextSection
                }

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                footerNote
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .navigationTitle(viewModel.mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") {
                    attemptCancel()
                }
                .accessibilityLabel("取消校对")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isShowingRawTextSheet = true
                    } label: {
                        Label("查看识别原文", systemImage: "text.alignleft")
                    }
                    .disabled(viewModel.rawText.isEmpty)

                    Button(role: .destructive) {
                        for field in CardFormField.allCases {
                            viewModel.clear(field)
                        }
                    } label: {
                        Label("清空全部字段", systemImage: "eraser")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多操作")
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(focusedField == .address || focusedField == nil ? "完成" : "下一项") {
                    if let focusedField {
                        focusNext(after: focusedField)
                    } else {
                        self.focusedField = nil
                    }
                }
            }
        }
        .fullScreenCover(item: $previewPayload) { payload in
            ImagePreviewSheet(
                image: payload.image,
                title: payload.title,
                onClose: { previewPayload = nil }
            )
        }
        .sheet(isPresented: $isShowingRawTextSheet) {
            rawTextSheet
        }
        .fullScreenCover(isPresented: $isShowingQuadEditor) {
            if let quadEditorImage {
                CardQuadEditorView(
                    image: quadEditorImage,
                    initialQuad: initialQuad ?? .cardDefault,
                    onConfirm: { quad in
                        applyManualQuad(quad)
                    },
                    onCancel: {
                        isShowingQuadEditor = false
                    }
                )
            }
        }
        // ⚠️ 同一个视图只保留一个 alert：两个 .alert 落在同一层时，iOS 只会
        // 生效其中一个，会出现「点取消没反应 / 点保存没反应」的假冻结。
        .alert(item: $activeAlert) { kind in
            switch kind {
            case .discard:
                return Alert(
                    title: Text("放弃修改？"),
                    message: Text("当前修改尚未保存，返回后将丢失。"),
                    primaryButton: .cancel(Text("继续编辑")),
                    secondaryButton: .destructive(Text("放弃")) {
                        dismiss()
                    }
                )
            case .duplicate:
                return Alert(
                    title: Text("可能重复添加"),
                    message: Text("已存在手机号或「姓名 + 公司」相同的名片，请确认是否继续保存。"),
                    primaryButton: .default(Text("仍然保存")) {
                        Task {
                            if let card = await viewModel.confirmDuplicateSave() {
                                completeSave(card)
                            }
                        }
                    },
                    secondaryButton: .cancel(Text("取消")) {
                        viewModel.dismissDuplicateWarning()
                    }
                )
            }
        }
        .onChange(of: viewModel.showDuplicateWarning) { _, isShowing in
            if isShowing {
                activeAlert = .duplicate
            }
        }
        .task {
            // 编辑模式：图片解码放到后台队列异步完成，避免进入页面时主线程卡顿。
            await viewModel.loadImagesIfNeeded()

            guard viewModel.mode.isCreate, viewModel.isLowConfidence else { return }
            try? await Task.sleep(for: .milliseconds(420))
            focusedField = viewModel.preferredFocusField
        }
    }

    // MARK: - 大图

    private var imageSection: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                guard let image = displayedImage else { return }
                previewPayload = ImagePreviewPayload(
                    image: image,
                    title: isShowingOriginal ? "名片原图" : "名片校正图"
                )
            } label: {
                ZStack {
                    Color.black.opacity(0.92)

                    if let image = displayedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else if viewModel.isLoadingImages {
                        VStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text("正在加载图片…")
                                .font(.caption)
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                            Text("图片不可用")
                                .font(.caption)
                        }
                        .foregroundStyle(.white.opacity(0.5))
                    }

                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.black.opacity(0.42)))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 232)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)

            if viewModel.hasDistinctProcessedImage {
                imageToggle
                    .padding(12)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var imageToggle: some View {
        HStack(spacing: 2) {
            imageToggleButton("校正图", isOriginal: false)
            imageToggleButton("原图", isOriginal: true)
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(.black.opacity(0.46))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func imageToggleButton(_ title: String, isOriginal: Bool) -> some View {
        Button {
            isShowingOriginal = isOriginal
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    isShowingOriginal == isOriginal
                        ? Color.black.opacity(0.82)
                        : Color.white.opacity(0.82)
                )
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            isShowingOriginal == isOriginal
                                ? Color.white
                                : Color.clear
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isShowingOriginal == isOriginal ? .isSelected : [])
    }

    private var displayedImage: UIImage? {
        isShowingOriginal ? viewModel.originalImage : viewModel.displayImage
    }

    // MARK: - 手动调整边角

    /// 只有扫描新建模式 + 有扫描流水线时才显示手动校正入口。
    private var canManuallyAdjustCorners: Bool {
        pipeline != nil && viewModel.canManuallyAdjustCorners
    }

    private var manualCornerEntry: some View {
        Button {
            openQuadEditor()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "crop")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.wasManuallyCorrected ? "重新调整名片边角" : "手动调整名片边角")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("自动校正不准？拖拽四角重新生成校正图")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if isPreparingQuadEditor || isApplyingManualQuad {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AppTheme.accent.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPreparingQuadEditor || isApplyingManualQuad)
        .accessibilityLabel("手动调整名片边角")
    }

    private func openQuadEditor() {
        guard let original = viewModel.originalImage else { return }
        isPreparingQuadEditor = true

        Task { @MainActor in
            // 方向归一化可能涉及大图重绘，放到后台执行，避免主线程卡顿。
            let normalized = await Task.detached(priority: .userInitiated) {
                original.normalizedUpImage()
            }.value

            isPreparingQuadEditor = false
            quadEditorImage = normalized
            isShowingQuadEditor = true
        }
    }

    private func applyManualQuad(_ quad: ManualCardQuad) {
        isShowingQuadEditor = false
        guard let pipeline, let original = viewModel.originalImage else { return }

        isApplyingManualQuad = true
        Task { @MainActor in
            let outcome = await pipeline.correctWithManualQuad(original, quad: quad)
            isApplyingManualQuad = false

            guard outcome.didDetectCardBoundary else {
                viewModel.errorMessage = "手动校正失败，请调整四角后重试"
                return
            }

            viewModel.applyManualCorrection(outcome.processedImage)
            isShowingOriginal = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: - 提示

    private var warningsBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(viewModel.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(
                        viewModel.isLowConfidence
                            ? Color.orange
                            : Color.secondary
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 1)
        )
    }

    private var metadataRow: some View {
        FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            metadataChip(
                text: viewModel.sourceDescription,
                systemImage: viewModel.source == .camera
                    ? "camera"
                    : "photo.on.rectangle",
                tint: .secondary
            )

            metadataChip(
                text: viewModel.wasManuallyCorrected
                    ? "已手动校正"
                    : (viewModel.didDetectCardBoundary ? "已自动校正" : "使用原图"),
                systemImage: viewModel.wasManuallyCorrected
                    ? "crop"
                    : (viewModel.didDetectCardBoundary
                        ? "checkmark.seal.fill"
                        : "exclamationmark.triangle.fill"),
                tint: viewModel.wasManuallyCorrected || viewModel.didDetectCardBoundary
                    ? .green
                    : .orange
            )

            metadataChip(
                text: viewModel.confidenceDescription,
                systemImage: viewModel.isLowConfidence
                    ? "exclamationmark.circle.fill"
                    : "checkmark.circle.fill",
                tint: viewModel.mode.isCreate
                    ? (viewModel.isLowConfidence ? .orange : .green)
                    : .secondary
            )

            metadataChip(
                text: "已填 \(viewModel.filledFieldCount) / 8",
                systemImage: "square.and.pencil",
                tint: .secondary
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataChip(
        text: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.10))
            )
    }

    // MARK: - 表单

    private var fieldSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("名片信息")
                    .font(.headline)
                Text("姓名 / 公司至少填写一项")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 2)

            ForEach(CardFormField.allCases) { field in
                CardFormFieldRow(
                    field: field,
                    text: Binding(
                        get: { viewModel.values[field] },
                        set: { viewModel.values[field] = $0 }
                    ),
                    focusedField: $focusedField,
                    onSubmit: { focusNext(after: field) }
                )
            }
        }
    }

    private func focusNext(after field: CardFormField) {
        let fields = CardFormField.allCases
        guard let index = fields.firstIndex(of: field) else { return }

        let nextIndex = fields.index(after: index)
        if nextIndex < fields.endIndex {
            focusedField = fields[nextIndex]
        } else {
            focusedField = nil
        }
    }

    // MARK: - 识别原文

    private var rawTextSection: some View {
        DisclosureGroup(isExpanded: $isShowingRawText) {
            ScrollView {
                Text(viewModel.rawText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 190)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            )
            .padding(.top, 8)
        } label: {
            Label("查看识别原文", systemImage: "text.alignleft")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - 底部操作

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                attemptCancel()
            } label: {
                Text("取消")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .disabled(viewModel.isSaving)

            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text(viewModel.isSaving ? "保存中…" : viewModel.mode.saveButtonTitle)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .disabled(viewModel.isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.4)
        }
    }

    private var footerNote: some View {
        Text("保存后会写入本机名片夹；图片与字段均不会上传。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.red.opacity(0.08))
            )
    }

    private var rawTextSheet: some View {
        NavigationStack {
            ScrollView {
                Text(viewModel.rawText)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("识别原文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        isShowingRawTextSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 保存 / 取消

    private func save() async {
        guard let card = await viewModel.save() else { return }

        // 保存成功后立即收尾：不再插入任何等待 / 让出（避免页面停留在
        // 「保存中…」、按钮被禁用的假冻结状态），直接复位弹窗与导航状态。
        completeSave(card)
    }

    private func completeSave(_ card: BusinessCard) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let onSaved {
            onSaved(card)
        } else {
            dismiss()
        }
    }

    private func attemptCancel() {
        if viewModel.hasUnsavedChanges {
            activeAlert = .discard
        } else {
            dismiss()
        }
    }
}
