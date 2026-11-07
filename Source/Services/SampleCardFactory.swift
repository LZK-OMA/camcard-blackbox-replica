//
//  SampleCardFactory.swift
//  CamCardClone
//
//  「模拟拍摄」使用的本地示例名片（数据来自 ground_truth.json TC01）。
//
//  生成两张图：
//  - photo：倾斜放在桌面上的拍摄照片，作为 original 图；
//  - croppedCard：正视卡片图，模拟区域检测 + 透视校正后的 processed 图。
//
//  整个绘制过程离线、确定性，便于 UI 演示与自动化测试。
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

    /// TC01 的 OCR 原文，与 ground_truth.json 保持一致。
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

    /// 取景页背景使用的纯卡片图（只渲染一次）。
    static let previewCardImage: UIImage = renderCard(size: CGSize(width: 1400, height: 800))

    static func makeCapture() -> SimulatedCapture {
        let cardSize = CGSize(width: 1400, height: 800)
        let cardImage = renderCard(size: cardSize)
        let photo = renderPhoto(cardImage: cardImage)

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
            croppedCard: cardImage,
            rawText: rawText,
            ocrLines: ocrLines
        )
    }

    // MARK: - 卡片

    private static func renderCard(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            let rect = CGRect(origin: .zero, size: size)

            UIColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1).setFill()
            context.fill(rect)

            // 左侧品牌色竖条
            let accent = UIColor(red: 0.06, green: 0.42, blue: 0.42, alpha: 1)
            accent.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 22, height: size.height))

            // 右上角淡色装饰
            let decoration = UIBezierPath(
                ovalIn: CGRect(
                    x: size.width - 360,
                    y: -190,
                    width: 560,
                    height: 560
                )
            )
            accent.withAlphaComponent(0.06).setFill()
            decoration.fill()

            // Logo
            let logoRect = CGRect(x: 92, y: 82, width: 104, height: 104)
            let logoPath = UIBezierPath(roundedRect: logoRect, cornerRadius: 26)
            accent.setFill()
            logoPath.fill()

            let logoAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 52, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let logoText = "星" as NSString
            let logoTextSize = logoText.size(withAttributes: logoAttributes)
            logoText.draw(
                at: CGPoint(
                    x: logoRect.midX - logoTextSize.width / 2,
                    y: logoRect.midY - logoTextSize.height / 2
                ),
                withAttributes: logoAttributes
            )

            // 公司
            let companyAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 42, weight: .semibold),
                .foregroundColor: UIColor(red: 0.10, green: 0.16, blue: 0.18, alpha: 1)
            ]
            ("星澜科技（深圳）有限公司" as NSString).draw(
                at: CGPoint(x: 232, y: 88),
                withAttributes: companyAttributes
            )

            let englishCompanyAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 19, weight: .medium),
                .foregroundColor: UIColor(red: 0.42, green: 0.48, blue: 0.49, alpha: 1),
                .kern: 0.8
            ]
            ("SHENZHEN XINGLAN TECHNOLOGY CO., LTD." as NSString).draw(
                at: CGPoint(x: 232, y: 148),
                withAttributes: englishCompanyAttributes
            )

            // 分隔线
            UIColor(red: 0.86, green: 0.88, blue: 0.87, alpha: 1).setFill()
            context.fill(CGRect(x: 92, y: 236, width: size.width - 184, height: 2))

            // 姓名 / 职位
            let nameAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 86, weight: .bold),
                .foregroundColor: UIColor(red: 0.08, green: 0.14, blue: 0.16, alpha: 1)
            ]
            ("陈亦舟" as NSString).draw(
                at: CGPoint(x: 92, y: 288),
                withAttributes: nameAttributes
            )

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .medium),
                .foregroundColor: accent
            ]
            ("产品总监" as NSString).draw(
                at: CGPoint(x: 96, y: 398),
                withAttributes: titleAttributes
            )

            // 联系方式
            let contactAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 26, weight: .regular),
                .foregroundColor: UIColor(red: 0.22, green: 0.27, blue: 0.28, alpha: 1)
            ]
            let contacts: [(String, String)] = [
                ("M", "138 0000 1234"),
                ("T", "0755-0000 5678"),
                ("E", "chen.yizhou@example.com"),
                ("W", "www.example.com"),
                ("A", "深圳市南山区科苑南路 0000 号 8 栋 1201")
            ]

            for (index, item) in contacts.enumerated() {
                let y = 500 + CGFloat(index) * 52
                let labelAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                    .foregroundColor: accent
                ]
                (item.0 as NSString).draw(
                    at: CGPoint(x: 96, y: y + 2),
                    withAttributes: labelAttributes
                )
                (item.1 as NSString).draw(
                    at: CGPoint(x: 140, y: y),
                    withAttributes: contactAttributes
                )
            }

            // Slogan
            let sloganAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .medium),
                .foregroundColor: UIColor(red: 0.55, green: 0.61, blue: 0.61, alpha: 1),
                .kern: 2.0
            ]
            let slogan = "让数据流动" as NSString
            let sloganSize = slogan.size(withAttributes: sloganAttributes)
            slogan.draw(
                at: CGPoint(
                    x: size.width - sloganSize.width - 92,
                    y: size.height - sloganSize.height - 58
                ),
                withAttributes: sloganAttributes
            )

            // 细边框
            UIColor(red: 0.90, green: 0.91, blue: 0.90, alpha: 1).setStroke()
            let border = UIBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
        }
    }

    // MARK: - 拍摄照片

    private static func renderPhoto(cardImage: UIImage) -> UIImage {
        let size = CGSize(width: 1700, height: 1200)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            let rect = CGRect(origin: .zero, size: size)

            let space = CGColorSpaceCreateDeviceRGB()
            let colors = [
                UIColor(red: 0.11, green: 0.13, blue: 0.15, alpha: 1).cgColor,
                UIColor(red: 0.23, green: 0.25, blue: 0.27, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: colors,
                locations: [0, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            context.saveGState()
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: -0.035)
            context.setShadow(
                offset: CGSize(width: 0, height: 28),
                blur: 46,
                color: UIColor.black.withAlphaComponent(0.55).cgColor
            )

            let cardRect = CGRect(
                x: -cardImage.size.width / 2,
                y: -cardImage.size.height / 2,
                width: cardImage.size.width,
                height: cardImage.size.height
            )
            cardImage.draw(in: cardRect)
            context.restoreGState()

            // 四周暗角
            if let vignette = CGGradient(
                colorsSpace: space,
                colors: [
                    UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.35).cgColor
                ] as CFArray,
                locations: [0.55, 1]
            ) {
                context.drawRadialGradient(
                    vignette,
                    startCenter: CGPoint(x: rect.midX, y: rect.midY),
                    startRadius: size.width * 0.25,
                    endCenter: CGPoint(x: rect.midX, y: rect.midY),
                    endRadius: size.width * 0.75,
                    options: [.drawsAfterEndLocation]
                )
            }
        }
    }
}
