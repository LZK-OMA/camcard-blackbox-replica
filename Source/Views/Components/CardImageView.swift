//
//  CardImageView.swift
//  CamCardClone
//
//  基于相对路径的异步缩略图视图。列表、详情与校对页共用。
//

import SwiftUI
import UIKit

struct CardImageView: View {

    let relativePath: String?
    var imageFileManager: CardImageFileManager = .shared
    var contentMode: ContentMode = .fill
    var maxPixelSize: CGFloat = 900
    var cornerRadius: CGFloat = 0

    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            placeholder

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: cacheKey) {
            await load()
        }
        .accessibilityHidden(true)
    }

    private var cacheKey: String {
        "\(relativePath ?? "nil")#\(Int(maxPixelSize))"
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .tertiarySystemFill),
                    Color(uiColor: .quaternarySystemFill)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func load() async {
        isLoading = true

        let loaded = await CardImageLoader.shared.image(
            relativePath: relativePath,
            using: imageFileManager,
            maxPixelSize: maxPixelSize
        )

        guard !Task.isCancelled else {
            // 行被回收 / 视图消失时任务会被取消：必须把 loading 复位，
            // 否则占位 ProgressView 会一直转（视觉上像卡死）。
            isLoading = false
            return
        }
        withAnimation(.easeOut(duration: 0.18)) {
            image = loaded
            isLoading = false
        }
    }
}
