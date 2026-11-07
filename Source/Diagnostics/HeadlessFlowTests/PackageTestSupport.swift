//
//  PackageTestSupport.swift
//  Diagnostics / HeadlessFlowTests
//
//  仅供 SwiftPM 无头测试使用的最小图片工厂（不属于 App 源码）。
//  与 TestRunner.swift 里的 makeImage 分开命名，避免与无头既有测试冲突。
//

import CoreGraphics
import UIKit

func makePackageTestImage(width: Int = 1200, height: Int = 760) -> UIImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return UIImage(cgImage: context.makeImage()!)
}
