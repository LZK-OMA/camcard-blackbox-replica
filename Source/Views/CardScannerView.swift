//
//  CardScannerView.swift
//  CamCardClone
//
//  扫描流程协调器：
//  - 把 AVFoundation 相机 / 相册选图交给 CameraCaptureView；
//  - 拿到图片后驱动 CardScanPipeline（区域校正 + OCR + 字段解析）；
//  - 完成后 push 人工校对页，保存仍由 CardCorrectionView 负责。
//
//  导航 / 呈现边界（冻结修复的关键）：
//  - 本视图内部持有 NavigationStack，因此**不能**在这里读取
//    `@Environment(\.dismiss)`：SwiftUI 已知缺陷会因非 Equatable 的
//    DismissAction 参与 body 求值而进入无限重绘（界面冻结、点击无响应）；
//  - 关闭全屏 cover 的职责上移到宿主 CardListView（通过 onRequestClose /
//    onComplete 闭包）；
//  - 保存成功后先复位 `reviewPresented`（让导航栈自己 pop），随即由宿主
//    关闭 cover，不插入任何等待或让出。
//

import SwiftUI
import UIKit

struct CardScannerView: View {

    // MARK: 依赖

    private let store: CardStore
    private let pipeline: CardScanPipeline
    private let startsWithPhotoPicker: Bool
    /// 请求关闭整条扫描流程（由宿主视图关闭 fullScreenCover）。
    private let onRequestClose: () -> Void
    /// 流程正常完成（名片已保存）。
    private let onComplete: (BusinessCard) -> Void

    // MARK: 状态

    @State private var viewModel: CardScannerViewModel

    init(
        store: CardStore,
        pipeline: CardScanPipeline,
        startsWithPhotoPicker: Bool = false,
        onRequestClose: @escaping () -> Void,
        onComplete: @escaping (BusinessCard) -> Void
    ) {
        self.store = store
        self.pipeline = pipeline
        self.startsWithPhotoPicker = startsWithPhotoPicker
        self.onRequestClose = onRequestClose
        self.onComplete = onComplete
        _viewModel = State(initialValue: CardScannerViewModel(pipeline: pipeline))
    }

    // MARK: - Body

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            ZStack {
                CameraCaptureView(
                    startsWithPhotoPicker: startsWithPhotoPicker,
                    onClose: {
                        viewModel.finishReview()
                        onRequestClose()
                    },
                    onImagePicked: { image, source in
                        viewModel.process(image: image, source: source)
                    },
                    onUseSample: {
                        viewModel.simulateCapture()
                    }
                )

                if viewModel.isProcessing {
                    processingOverlay(stage: viewModel.stage)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: viewModel.isProcessing)
            .toolbar(.hidden, for: .navigationBar)
            .statusBarHidden(true)
            .navigationDestination(isPresented: $viewModel.reviewPresented) {
                if let draft = viewModel.draft {
                    CardCorrectionView(
                        mode: .create(draft),
                        store: store,
                        pipeline: pipeline,
                        initialQuad: viewModel.detectedQuad
                    ) { card in
                        // 保存成功：只先复位导航标志（让栈 pop），草稿在
                        // onDisappear 里统一清理；随后宿主立即关闭 cover。
                        // 这里没有任何 Task.sleep / 让出 / 阻塞等待。
                        viewModel.dismissReview()
                        onComplete(card)
                    }
                    .onDisappear {
                        // 用户取消 / 返回时同样复位，避免 reviewPresented
                        // 残留 true 导致后续扫描无法再次 push。
                        viewModel.finishReview()
                    }
                } else {
                    EmptyView()
                }
            }
            .alert(item: $viewModel.failure) { failure in
                if failure.image != nil {
                    return Alert(
                        title: Text(failure.title),
                        message: Text(failure.message),
                        primaryButton: .default(Text("手动填写")) {
                            viewModel.startManualEntry(from: failure)
                        },
                        secondaryButton: .cancel(Text("取消"))
                    )
                }
                return Alert(
                    title: Text(failure.title),
                    message: Text(failure.message),
                    dismissButton: .default(Text("好"))
                )
            }
        }
    }

    // MARK: - 处理进度

    private func processingOverlay(stage: CardScanStage) -> some View {
        ZStack {
            Color.black.opacity(0.68)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(0.10), lineWidth: 4)
                        .frame(width: 68, height: 68)

                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }

                VStack(spacing: 6) {
                    Text(stage.title)
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text("正在本地处理，请稍候")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }

                VStack(alignment: .leading, spacing: 11) {
                    ForEach(CardScanStage.allCases) { item in
                        stageRow(item, current: stage)
                    }
                }
                .padding(.top, 4)

                Button {
                    viewModel.cancelCurrentTask()
                } label: {
                    Text("取消")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.white.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.14).opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 34)
        }
    }

    private func stageRow(_ item: CardScanStage, current: CardScanStage) -> some View {
        let isDone = item.order < current.order
        let isCurrent = item == current

        return HStack(spacing: 10) {
            Group {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.accent)
                } else if isCurrent {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.white.opacity(0.22))
                }
            }
            .font(.system(size: 14))
            .frame(width: 18, height: 18)

            Text(item.title)
                .font(.caption)
                .foregroundStyle(
                    isDone || isCurrent ? .white.opacity(0.9) : .white.opacity(0.34)
                )

            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.2), value: current)
    }
}
