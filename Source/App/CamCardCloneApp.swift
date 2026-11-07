//
//  CamCardCloneApp.swift
//  CamCardClone
//
//  @main 入口。启动阶段采用「先渲染、后装配」：
//  1. 首帧只渲染轻量启动占位页，让系统尽快提交画面，不再展示上一次的启动快照；
//  2. SwiftData 容器与依赖树在后台线程装配，绝不阻塞主 RunLoop（否则整屏无响应）；
//  3. 装配失败时展示可重试的错误页，而不是永久停留在不可交互的加载页。
//

import SwiftData
import SwiftUI

@main
struct CamCardCloneApp: App {

    @State private var environment: AppEnvironment?

    /// 启动装配失败时的提示；nil 表示仍在装配或已成功。
    @State private var startupFailure: String?

    /// 重试次数。自增会让 `.task(id:)` 重新执行装配，旧任务自动取消。
    @State private var bootstrapAttempt = 0

    var body: some Scene {
        WindowGroup {
            Group {
                if let environment {
                    RootView()
                        .environment(environment)
                        .modelContainer(environment.container)
                        .tint(AppTheme.accent)
                } else {
                    StartupPlaceholderView(
                        failureMessage: startupFailure,
                        onRetry: { bootstrapAttempt += 1 }
                    )
                }
            }
            // 只在「还没有环境」时装配；重试通过 id 变化重新触发。
            .task(id: bootstrapAttempt) {
                await bootstrapEnvironmentIfNeeded()
            }
        }
    }

    /// 启动装配唯一入口。整个过程在主线程之外创建容器，主线程始终可响应手势。
    @MainActor
    private func bootstrapEnvironmentIfNeeded() async {
        guard environment == nil else { return }
        startupFailure = nil
        do {
            let resolved = try await AppEnvironment.makeForAppLaunchAsync()
            // 装配期间可能已经有另一次尝试成功，避免覆盖。
            guard environment == nil else { return }
            environment = resolved
        } catch {
            startupFailure = "无法初始化本地数据存储：\(error.localizedDescription)"
        }
    }
}

// MARK: - 启动占位

/// 启动占位页：加载中 / 失败可重试。
///
/// 这是一个独立的全屏页，装配成功后会被 `RootView` 整体替换，
/// 不会残留在视图树顶层继续拦截手势。
private struct StartupPlaceholderView: View {

    let failureMessage: String?
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            if let failureMessage {
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.orange)

                    Text("启动失败")
                        .font(.headline)

                    Text(failureMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button("重试", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(AppTheme.accent)
                }
            } else {
                ProgressView("正在启动...")
            }
        }
    }
}
