//
//  CardScannerViewModel.swift
//  CamCardClone
//
//  取景 / 导入页 ViewModel。
//  它只负责驱动阶段状态与生成草稿；真正的保存发生在人工校对页。
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class CardScannerViewModel {

    struct ScanFailure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let image: UIImage?
        let source: CardSource
    }

    // MARK: 输出

    private(set) var stage: CardScanStage = .detecting
    private(set) var isProcessing = false
    private(set) var draft: ScanDraft?
    var reviewPresented = false
    var failure: ScanFailure?

    /// 本次扫描检测到的四角（供校对页「手动调整边角」做初始值）。
    private(set) var detectedQuad: ManualCardQuad?

    // MARK: 依赖

    private let pipeline: CardScanPipeline
    @ObservationIgnored private var activeTask: Task<Void, Never>?

    /// 每次扫描的世代号。取消 / 重新扫描会自增，旧任务据此放弃一切状态写入，
    /// 避免「陈旧任务在结束时把新一轮扫描的 isProcessing 改坏」这类竞态。
    @ObservationIgnored private var runID: UInt = 0

    init(pipeline: CardScanPipeline) {
        self.pipeline = pipeline
    }

    // MARK: - 模拟拍摄

    func simulateCapture() {
        guard !isProcessing else { return }

        runID &+= 1
        let currentRun = runID

        isProcessing = true
        draft = nil
        detectedQuad = nil
        stage = .detecting
        reviewPresented = false

        activeTask?.cancel()
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // 无论从哪个分支退出（含取消），只要本轮仍是当前扫描，就保证把
            // isProcessing 复位，避免全屏进度覆盖层永久挡住界面。
            defer {
                if self.runID == currentRun, self.isProcessing {
                    self.isProcessing = false
                }
            }

            // 用很短的阶段停顿展示流水线，不伪造识别结果本身：
            // 字段仍然由 BusinessCardFieldParser 对 TC01 原文解析得到。
            for stage in [CardScanStage.detecting, .correcting, .recognizing, .extracting] {
                guard !Task.isCancelled, self.runID == currentRun else { return }
                self.stage = stage
                try? await Task.sleep(for: .milliseconds(260))
            }

            guard !Task.isCancelled, self.runID == currentRun else { return }

            let draft = self.pipeline.makeSimulatedDraft()
            self.stage = .ready
            try? await Task.sleep(for: .milliseconds(180))

            guard !Task.isCancelled, self.runID == currentRun else { return }
            self.draft = draft
            self.isProcessing = false
            self.reviewPresented = true
        }
    }

    // MARK: - 相机 / 相册图片

    func process(image: UIImage, source: CardSource) {
        guard !isProcessing else { return }

        runID &+= 1
        let currentRun = runID

        isProcessing = true
        draft = nil
        detectedQuad = nil
        stage = .detecting
        reviewPresented = false

        activeTask?.cancel()
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // 兜底复位：任何退出路径（取消 / 抛错 / 提前 return）都不会让
            // isProcessing 永远停在 true（否则全屏进度层会永久拦截点击）。
            defer {
                if self.runID == currentRun, self.isProcessing {
                    self.isProcessing = false
                }
            }

            let outcome = await self.pipeline.correct(image)
            guard !Task.isCancelled, self.runID == currentRun else { return }

            self.detectedQuad = outcome.detectedQuad
            self.stage = .recognizing
            do {
                let ocr = try await self.pipeline.recognize(outcome.processedImage)
                guard !Task.isCancelled, self.runID == currentRun else { return }

                self.stage = .extracting
                let fields = self.pipeline.extract(ocr.rawText)
                let draft = self.pipeline.makeDraft(
                    originalImage: image,
                    outcome: outcome,
                    ocr: ocr,
                    fields: fields,
                    source: source
                )

                self.stage = .ready
                self.draft = draft
                self.isProcessing = false
                self.reviewPresented = true
            } catch {
                guard !Task.isCancelled, self.runID == currentRun else { return }
                self.isProcessing = false
                self.failure = ScanFailure(
                    title: "识别失败",
                    message: error.localizedDescription,
                    image: image,
                    source: source
                )
            }
        }
    }

    // MARK: - 兜底

    /// OCR 失败时保留图片，进入字段全空的人工录入模式。
    func startManualEntry(from failure: ScanFailure) {
        guard let image = failure.image else { return }

        runID &+= 1

        let draft = pipeline.makeManualDraft(
            originalImage: image,
            source: failure.source,
            reason: failure.message
        )
        self.draft = draft
        self.failure = nil
        self.isProcessing = false
        self.stage = .ready
        self.reviewPresented = true
    }

    func reportImageLoadFailure(_ message: String) {
        failure = ScanFailure(
            title: "无法读取图片",
            message: message,
            image: nil,
            source: .photoLibrary
        )
    }

    func discardDraft() {
        draft = nil
        stage = .detecting
        reviewPresented = false
    }

    /// 保存成功 / 退出校对时只复位导航标志，让 NavigationStack 先完成 pop；
    /// 草稿与阶段状态由 `finishReview()`（onDisappear 时）统一清理。
    func dismissReview() {
        reviewPresented = false
    }

    /// 校对流程结束（保存成功 / 用户取消）时复位整条扫描流水线。
    ///
    /// 关键点：
    /// - 必须把 `reviewPresented` 置回 false，让 NavigationStack 自己 pop，
    ///   再由宿主视图关闭全屏 cover；直接在被 push 的页面上关闭宿主 cover
    ///   会触发 SwiftUI 导航状态竞争（已知会冻结 UI）。
    /// - 同时清空 draft，避免下一次扫描出现「reviewPresented == true 但 draft == nil」
    ///   的非法组合导致 push 被丢弃、此后永远进不了校对页。
    func finishReview() {
        activeTask?.cancel()
        activeTask = nil
        runID &+= 1

        draft = nil
        detectedQuad = nil
        stage = .detecting
        isProcessing = false
        reviewPresented = false
    }

    func cancelCurrentTask() {
        activeTask?.cancel()
        activeTask = nil
        runID &+= 1
        isProcessing = false
    }
}
