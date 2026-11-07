//
//  CardImageLoader.swift
//  CamCardClone
//
//  沙盒图片的异步加载与降采样。
//
//  列表 / 详情只保存相对路径，加载时：
//  1. 由 CardImageFileManager 解析为当前沙盒下的绝对 URL；
//  2. 用 ImageIO 直接生成缩略图，避免把 12MP 原图整张解码进内存；
//  3. 以「绝对路径 + 目标像素」为键做 NSCache，滚动列表时不重复解码。
//
//  线程模型（与主线程死锁相关，禁止回退）：
//  - 本类的 `image(...)` 可能从主线程（SwiftUI .task）调用，
//    因此**路径解析、文件存在性检查、NSCache 访问、ImageIO 解码全部**
//    放在专用后台队列执行，主线程只 `await` 结果；
//  - 主线程绝不触碰 NSCache / ImageIO / FileManager 的内部锁，
//    避免与后台解码线程在 pthread mutex 上互相等待（表现为整屏点不动、CPU 0%）。
//

import Foundation
import ImageIO
import UIKit

// MARK: - 线程安全缓存

private final class CardImageCache: @unchecked Sendable {

    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 160
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

// MARK: - Loader

final class CardImageLoader: @unchecked Sendable {

    static let shared = CardImageLoader()

    private let cache = CardImageCache()
    private let queue = DispatchQueue(
        label: "com.camcard.image-loader",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {}

    /// 异步读取图片，并按 `maxPixelSize` 生成缩略图。
    ///
    /// 整个实现只做一件事：把全部工作（含缓存查询与文件检查）派发到后台队列，
    /// 通过 continuation 把结果带回调用方；主线程不执行任何可能触碰系统锁的同步操作。
    func image(
        relativePath: String?,
        using fileManager: CardImageFileManager,
        maxPixelSize: CGFloat = 900
    ) async -> UIImage? {
        let targetSize = max(64, Int(maxPixelSize))

        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            queue.async { [cache] in
                // —— 以下全部在后台队列执行 ——
                guard let relativePath,
                      !relativePath.isEmpty,
                      let url = fileManager.imageURL(for: relativePath),
                      FileManager.default.fileExists(atPath: url.path) else {
                    continuation.resume(returning: nil)
                    return
                }

                let key = "\(url.path)#\(targetSize)"

                if let cached = cache.image(forKey: key) {
                    continuation.resume(returning: cached)
                    return
                }

                guard let image = Self.downsample(url: url, maxPixelSize: targetSize) else {
                    continuation.resume(returning: nil)
                    return
                }

                let cost = Int(
                    image.size.width * image.scale
                        * image.size.height * image.scale * 4
                )
                cache.insert(image, forKey: key, cost: cost)
                continuation.resume(returning: image)
            }
        }
    }

    func clearCache() {
        queue.async { [cache] in
            cache.removeAll()
        }
    }

    // MARK: - ImageIO

    private static func downsample(url: URL, maxPixelSize: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            sourceOptions as CFDictionary
        ) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return UIImage(contentsOfFile: url.path)
        }

        return UIImage(cgImage: cgImage)
    }
}
