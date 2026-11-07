//
//  CardQuadEditorView.swift
//  CamCardClone
//
//  手动四角校正编辑器。
//
//  使用场景（spec R-02/R-03、E-DET-001）：
//  - 自动检测名片边缘失败、降级使用原图时，用户可从这里手动拖拽四角；
//  - 自动校正结果不满意时，也可以重新指定四角。
//
//  设计约束：
//  - 本视图自身持有 NavigationStack，因此**不能**读取 @Environment(\.dismiss)，
//    关闭动作全部由宿主通过 onCancel / onConfirm 闭包驱动
//    （避免之前踩过的 SwiftUI DismissAction 冻结缺陷）。
//  - 四角坐标使用归一化的「左上角原点」坐标系（ManualCardQuad），与流水线解耦。
//

import SwiftUI
import UIKit

struct CardQuadEditorView: View {

    // MARK: - 依赖

    let image: UIImage
    private let initialQuad: ManualCardQuad
    private let onConfirm: (ManualCardQuad) -> Void
    private let onCancel: () -> Void

    // MARK: - 状态

    @State private var quad: ManualCardQuad
    @State private var isShowingInvalidAlert = false

    init(
        image: UIImage,
        initialQuad: ManualCardQuad,
        onConfirm: @escaping (ManualCardQuad) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.image = image
        let clamped = initialQuad.clamped()
        self.initialQuad = clamped
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _quad = State(initialValue: clamped)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { proxy in
                    editorCanvas(size: proxy.size)
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)

                hintRow
                bottomBar
            }
            .padding(.bottom, 8)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("调整名片边角")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        onCancel()
                    }
                    .accessibilityLabel("取消调整边角")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        if quad.isValid {
                            onConfirm(quad)
                        } else {
                            isShowingInvalidAlert = true
                        }
                    }
                    .fontWeight(.semibold)
                    .accessibilityLabel("完成调整边角")
                }
            }
            .alert("四角位置无效", isPresented: $isShowingInvalidAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请让四个角按「左上 → 右上 → 右下 → 左下」的顺序，围出一块有效的名片区域。")
            }
        }
    }

    // MARK: - 画布

    private func editorCanvas(size: CGSize) -> some View {
        let imageRect = Self.fittedRect(imageSize: image.size, in: size, padding: 18)

        return ZStack {
            Color.black

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: imageRect.width, height: imageRect.height)
                .position(x: imageRect.midX, y: imageRect.midY)

            // 选区高亮 + 四角连线
            QuadPolygon(points: quad.corners.map { Self.displayPoint($0, in: imageRect) })
                .fill(AppTheme.accent.opacity(0.14))

            QuadPolygon(points: quad.corners.map { Self.displayPoint($0, in: imageRect) })
                .stroke(
                    AppTheme.accent,
                    style: StrokeStyle(lineWidth: 2, lineJoin: .round)
                )

            // 四角拖拽手柄（顺序：0 左上 / 1 右上 / 2 右下 / 3 左下）
            ForEach(0..<4, id: \.self) { index in
                let point = Self.displayPoint(quad.corners[index], in: imageRect)

                Circle()
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle().strokeBorder(AppTheme.accent, lineWidth: 3)
                    )
                    .overlay(
                        Circle()
                            .fill(AppTheme.accent.opacity(0.9))
                            .frame(width: 8, height: 8)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 2)
                    .position(point)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("quadCanvas"))
                            .onChanged { value in
                                quad.setCorner(
                                    index,
                                    to: Self.normalizedPoint(value.location, in: imageRect)
                                )
                            }
                    )
                    .accessibilityElement()
                    .accessibilityLabel(Self.cornerLabel(index))
            }
        }
        .coordinateSpace(name: "quadCanvas")
        .accessibilityIdentifier("quadEditorCanvas")
    }

    // MARK: - 提示 / 操作

    private var hintRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw")
                .foregroundStyle(AppTheme.accent)
            Text("拖动四个白色圆点，让四角贴住名片边缘")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("重置") {
                quad = initialQuad
            }
            .accessibilityLabel("重置四角")
        }
        .font(.footnote)
        .padding(.horizontal, 20)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("确认后会重新生成校正图；不会重新识别文字，也不影响已识别的字段。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - 坐标换算

    /// 图片按 aspectFit 放进画布后的实际显示区域。
    private static func fittedRect(
        imageSize: CGSize,
        in container: CGSize,
        padding: CGFloat
    ) -> CGRect {
        let available = CGSize(
            width: max(1, container.width - padding * 2),
            height: max(1, container.height - padding * 2)
        )
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: available)
        }

        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// 归一化（左上原点）→ 画布坐标。
    private static func displayPoint(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + normalized.x * rect.width,
            y: rect.minY + normalized.y * rect.height
        )
    }

    /// 画布坐标 → 归一化（左上原点），并限制在图像范围内。
    private static func normalizedPoint(_ location: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((location.x - rect.minX) / rect.width, 0), 1),
            y: min(max((location.y - rect.minY) / rect.height, 0), 1)
        )
    }

    private static func cornerLabel(_ index: Int) -> String {
        switch index {
        case 0: return "左上角"
        case 1: return "右上角"
        case 2: return "右下角"
        default: return "左下角"
        }
    }
}

// MARK: - 四边形路径

private struct QuadPolygon: Shape {

    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
