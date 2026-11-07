//
//  UIKit.swift
//  Diagnostics / HeadlessFlowTests
//
//  只用于 macOS 上的无头逻辑测试：提供一个最小可用的 `UIKit` 模块替身，
//  让 App 里真实的 ViewModel / Store / 文件管理器可以脱离 iOS 模拟器编译并执行。
//
//  这不是 App 的一部分，不参与 iOS Target 构建。
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - UIImage

public final class UIImage {

    public enum Orientation: Int, Sendable {
        case up = 0
        case down = 1
        case left = 2
        case right = 3
        case upMirrored = 4
        case downMirrored = 5
        case leftMirrored = 6
        case rightMirrored = 7
    }

    public let cgImage: CGImage?
    public let scale: CGFloat
    public let imageOrientation: Orientation

    public init(cgImage: CGImage, scale: CGFloat = 1, orientation: Orientation = .up) {
        self.cgImage = cgImage
        self.scale = scale
        self.imageOrientation = orientation
    }

    /// 空图片（对齐 UIKit 的 `UIImage()`，size == .zero），用于测试保存失败分支。
    public init() {
        self.cgImage = nil
        self.scale = 1
        self.imageOrientation = .up
    }

    public convenience init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        self.init(cgImage: cg)
    }

    public convenience init?(contentsOfFile path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        self.init(data: data)
    }

    public var size: CGSize {
        guard let cgImage else { return .zero }
        return CGSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        )
    }

    public func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            cgImage,
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 替身不真正绘制，仅用于保持与 UIKit API 形状一致。
    public func draw(in rect: CGRect) {}
}

// MARK: - 渲染器替身

public final class UIGraphicsImageRendererContext {
    public var cgContext: CGContext?
    public init(cgContext: CGContext?) {
        self.cgContext = cgContext
    }
}

public final class UIGraphicsImageRendererFormat {
    public var scale: CGFloat = 1
    public var opaque: Bool = false

    public init() {}

    public static func `default`() -> UIGraphicsImageRendererFormat {
        UIGraphicsImageRendererFormat()
    }
}

public final class UIGraphicsImageRenderer {

    private let targetSize: CGSize
    private let format: UIGraphicsImageRendererFormat

    public init(size: CGSize, format: UIGraphicsImageRendererFormat = .default()) {
        self.targetSize = size
        self.format = format
    }

    public func image(actions: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let width = max(1, Int((targetSize.width * format.scale).rounded()))
        let height = max(1, Int((targetSize.height * format.scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )

        if let context {
            actions(UIGraphicsImageRendererContext(cgContext: context))
        }

        guard let rendered = context?.makeImage() else {
            let fallbackSpace = CGColorSpaceCreateDeviceRGB()
            let fallbackContext = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: fallbackSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            return UIImage(cgImage: fallbackContext!.makeImage()!)
        }
        return UIImage(cgImage: rendered, scale: format.scale)
    }
}
