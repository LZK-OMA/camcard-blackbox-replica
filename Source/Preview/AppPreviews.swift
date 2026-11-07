//
//  AppPreviews.swift
//  CamCardClone
//
//  Xcode Preview 入口。使用内存容器 + 3 条 Mock 名片，图片写入 tmp，不污染真实沙盒。
//

import SwiftUI

#if DEBUG

#Preview("名片夹") {
    let environment = AppEnvironment.preview()

    CardListView(
        store: environment.cardStore,
        scanPipeline: environment.scanPipeline,
        exporter: environment.contactExporter
    )
    .tint(AppTheme.accent)
}

#Preview("相机拍摄") {
    CameraCaptureView(
        onClose: {},
        onImagePicked: { _, _ in },
        onUseSample: {}
    )
}

#Preview("扫描流程") {
    let environment = AppEnvironment.preview()

    CardScannerView(
        store: environment.cardStore,
        pipeline: environment.scanPipeline,
        onRequestClose: {},
        onComplete: { _ in }
    )
}

#Preview("人工校对") {
    let environment = AppEnvironment.preview()
    let draft = environment.scanPipeline.makeSimulatedDraft()

    NavigationStack {
        CardCorrectionView(
            mode: .create(draft),
            store: environment.cardStore
        )
    }
    .tint(AppTheme.accent)
}

#Preview("名片详情") {
    let environment = AppEnvironment.preview()

    NavigationStack {
        if let card = environment.cardStore.cards.first {
            CardDetailView(
                card: card,
                store: environment.cardStore,
                exporter: environment.contactExporter
            )
        } else {
            Text("Mock 数据为空")
        }
    }
    .tint(AppTheme.accent)
}

#endif
