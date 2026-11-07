//
//  Stubs.swift
//  Diagnostics / HeadlessFlowTests
//
//  仅用于无头测试的替身（不属于 App 源码）：
//  真实的 SampleCardFactory 依赖 UIKit 绘图（UIFont / UIColor / 渲染上下文），
//  与本次要验证的「状态流转 / 保存链路」无关，因此在这里提供同形状的最小替身。
//

import Foundation
import UIKit

enum SampleCardFactory {

    struct SimulatedCapture {
        let photo: UIImage
        let croppedCard: UIImage
        let rawText: String
        let ocrLines: [OCRTextLine]
    }

    static let rawText = """
    星澜科技（深圳）有限公司
    SHENZHEN XINGLAN TECHNOLOGY CO., LTD.
    产品总监  陈亦舟
    Mobile 138 0000 1234
    Tel: 0755-0000 5678
    E-mail: Chen.Yizhou@Example.com
    www.example.com
    深圳市南山区科苑南路 0000 号 8 栋 1201
    让数据流动
    """

    static func makeCapture() -> SimulatedCapture {
        let photo = makePackageTestImage(width: 1400, height: 900)
        let card = makePackageTestImage(width: 1400, height: 800)

        let ocrLines = rawText
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated()
            .map { index, text in
                OCRTextLine(
                    text: text,
                    confidence: 0.92 + Float(index % 5) * 0.01,
                    boundingBox: CGRect(
                        x: 0.08,
                        y: CGFloat(max(0.04, 0.88 - Double(index) * 0.09)),
                        width: 0.84,
                        height: 0.06
                    )
                )
            }

        return SimulatedCapture(
            photo: photo,
            croppedCard: card,
            rawText: rawText,
            ocrLines: ocrLines
        )
    }
}
