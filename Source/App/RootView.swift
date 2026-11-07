//
//  RootView.swift
//  CamCardClone
//
//  根视图：仅承载名片夹。扫描流程使用全屏覆盖，校对页在内部 NavigationStack 中 push。
//
//  导航层级契约（手势阻断问题的关键，禁止改动）：
//  - 整个 App 有且只有一个 NavigationStack，由 CardListView 自己持有；
//  - RootView 绝不能再次包裹 NavigationStack —— 否则两层栈互相吞掉手势，
//    首页所有点击都会「没有反应」；
//  - 这里也不能添加全屏 Overlay / 透明手势层 / .disabled / .allowsHitTesting(false)，
//    根视图只负责把 AppEnvironment 注入给 CardListView。
//

import SwiftUI

struct RootView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        CardListView(
            store: environment.cardStore,
            scanPipeline: environment.scanPipeline,
            exporter: environment.contactExporter,
            startupWarning: environment.startupWarning
        )
        .tint(AppTheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
