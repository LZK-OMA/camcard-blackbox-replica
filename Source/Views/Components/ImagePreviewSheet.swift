//
//  ImagePreviewSheet.swift
//  CamCardClone
//
//  全屏名片大图预览，支持双指缩放、双击复位。
//

import SwiftUI
import UIKit

struct ImagePreviewSheet: View {

    let image: UIImage
    var title: String = "名片原图"

    /// 关闭动作由宿主传入。
    /// 这里刻意不读取 `@Environment(\.dismiss)`：本视图自身持有 NavigationStack，
    /// 在「持有导航栈的视图」里读取非 Equatable 的 DismissAction 会踩中 SwiftUI
    /// 已知的无限重绘冻结缺陷（表现为整屏黑图、所有手势失效）。
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(max(steadyScale * value, 1), 5)
                                }
                                .onEnded { _ in
                                    steadyScale = scale
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                scale = scale > 1 ? 1 : 2.2
                                steadyScale = scale
                            }
                        }
                        .accessibilityLabel(title)
                }

                VStack {
                    Spacer()
                    Text(scale > 1 ? "双指缩放 · 双击复位" : "双指缩放 · 双击放大")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("关闭")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}
