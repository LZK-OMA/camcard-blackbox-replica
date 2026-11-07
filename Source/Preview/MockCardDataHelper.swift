//
//  MockCardDataHelper.swift
//  CamCardClone
//
//  Preview / 单元测试用虚拟名片。
//  数据取自 ground_truth.json 的 TC01 / TC04 / TC21：
//  - TC01：全字段金样本；
//  - TC04：中英双语 + 手机/办公/传真；
//  - TC21：仅有邮箱与网址，mobile/phone/fax/address 均为 nil。
//
//  ID 固定，便于测试断言与重复 seed 时幂等覆盖。
//

import Foundation
import SwiftData
import UIKit

@MainActor
enum MockCardDataHelper {

    // MARK: - 固定标识

    private static let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()
    private static let secondID = UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID()
    private static let thirdID = UUID(uuidString: "21212121-2121-2121-2121-212121212121") ?? UUID()

    /// 2026-01-01T10:00:00+08:00
    private static let firstDate = Date(timeIntervalSince1970: 1_767_232_800)
    /// 2026-01-02T09:30:00+08:00
    private static let secondDate = Date(timeIntervalSince1970: 1_767_317_400)
    /// 2026-01-03T16:45:00+08:00
    private static let thirdDate = Date(timeIntervalSince1970: 1_767_429_900)

    // MARK: - 预置数据

    /// 创建 3 条虚拟名片（不写数据库、不生成图片文件）。
    /// 返回的 `originalImageFilename` 为占位相对路径；若需要真实图片，请调用 `seed(...)`。
    static func makeCards() -> [BusinessCard] {
        let first = BusinessCard(
            id: firstID,
            name: "陈亦舟",
            company: "星澜科技（深圳）有限公司",
            jobTitle: "产品总监",
            mobile: "13800001234",
            phone: "075500005678",
            fax: nil,
            email: "chen.yizhou@example.com",
            website: "https://www.example.com",
            address: "深圳市南山区科苑南路 0000 号 8 栋 1201",
            tags: ["客户", "展会"],
            notes: "2026 春季展会收集，重点跟进。",
            originalImageFilename: "\(firstID.uuidString)/original.heic",
            processedImageFilename: "\(firstID.uuidString)/processed.heic",
            createdAt: firstDate,
            updatedAt: firstDate,
            source: .camera
        )

        let second = BusinessCard(
            id: secondID,
            name: "周慕青 Zhou Muqing",
            company: "澜庭国际酒店集团",
            jobTitle: "市场总监 / Marketing Director",
            mobile: "13600005555",
            phone: "01000006666",
            fax: "01000007777",
            email: "muqing.zhou@example.com",
            website: "https://www.example.com/lanting",
            address: "北京市朝阳区建国路 0000 号 澜庭大厦 18 层",
            tags: ["合作伙伴", "酒店"],
            notes: nil,
            originalImageFilename: "\(secondID.uuidString)/original.heic",
            processedImageFilename: "\(secondID.uuidString)/processed.heic",
            createdAt: secondDate,
            updatedAt: secondDate,
            source: .photoLibrary
        )

        let third = BusinessCard(
            id: thirdID,
            name: "方黎 Fang Li",
            company: "黎岸工作室",
            jobTitle: "独立插画师 / Illustrator",
            mobile: nil,
            phone: nil,
            fax: nil,
            email: "fangli@example.com",
            website: "https://www.example.com/lian",
            address: nil,
            tags: ["设计师"],
            notes: nil,
            originalImageFilename: "\(thirdID.uuidString)/original.heic",
            processedImageFilename: nil,
            createdAt: thirdDate,
            updatedAt: thirdDate,
            source: .file
        )

        return [first, second, third]
    }

    // MARK: - 写入 ModelContext

    /// 把 3 条虚拟名片写入指定上下文。
    ///
    /// - Parameters:
    ///   - context: 通常来自内存容器；持久化容器也可用（固定 ID 保证幂等覆盖）。
    ///   - generateImages: 是否生成占位图片并写入 Documents/Cards/。
    ///     单元测试若只验证数据库，可传 false 避免文件 IO。
    ///   - imageFileManager: 图片文件管理器；Preview 可注入临时目录避免污染 Documents。
    /// - Returns: 实际写入上下文的对象（已存在时返回原对象）。
    @discardableResult
    static func seed(
        into context: ModelContext,
        generateImages: Bool = true,
        imageFileManager: CardImageFileManager = .shared
    ) throws -> [BusinessCard] {
        let cards = makeCards()

        if generateImages {
            for (index, card) in cards.enumerated() {
                let image = makePlaceholderImage(for: card, index: index)
                card.originalImageFilename = try imageFileManager.saveOriginal(
                    image,
                    cardID: card.id
                )

                if card.processedImageFilename != nil {
                    card.processedImageFilename = try imageFileManager.saveProcessed(
                        image,
                        cardID: card.id
                    )
                }
                card.sanitize()
            }
        }

        let existingCards = try context.fetch(FetchDescriptor<BusinessCard>())
        var existingByID: [UUID: BusinessCard] = [:]
        for existing in existingCards {
            existingByID[existing.id] = existing
        }

        var result: [BusinessCard] = []
        for card in cards {
            if let stored = existingByID[card.id] {
                // 幂等覆盖：保留 id / createdAt 的稳定性，刷新其余内容与图片路径。
                stored.applyContent(from: card)
                stored.createdAt = card.createdAt
                stored.updatedAt = card.updatedAt
                stored.sanitize()
                result.append(stored)
            } else {
                context.insert(card)
                result.append(card)
            }
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        return result
    }

    // MARK: - Preview 容器

    /// 创建带 3 条 mock 数据的内存容器，供 SwiftUI `#Preview` 使用。
    /// 图片写入临时目录，避免污染真实 Documents。
    static func makePreviewContainer(seedImages: Bool = true) throws -> ModelContainer {
        let container = try ModelContainer(
            for: BusinessCard.self,
            configurations: ModelConfiguration(
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        )

        let previewRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CamCardPreview", isDirectory: true)
        let previewImageManager = CardImageFileManager(baseDirectory: previewRoot)

        try seed(
            into: container.mainContext,
            generateImages: seedImages,
            imageFileManager: previewImageManager
        )
        return container
    }

    // MARK: - 占位图片

    private static func makePlaceholderImage(for card: BusinessCard, index: Int) -> UIImage {
        let size = CGSize(width: 1200, height: 750)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let palette: [UIColor] = [
            UIColor(red: 0.10, green: 0.32, blue: 0.56, alpha: 1),
            UIColor(red: 0.16, green: 0.45, blue: 0.38, alpha: 1),
            UIColor(red: 0.48, green: 0.25, blue: 0.42, alpha: 1)
        ]
        let background = palette[index % palette.count]

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            background.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))

            let cardRect = CGRect(
                x: 80,
                y: 80,
                width: size.width - 160,
                height: size.height - 160
            )
            UIColor.white.withAlphaComponent(0.12).setFill()
            UIBezierPath(roundedRect: cardRect, cornerRadius: 28).fill()

            let title = card.name ?? card.company ?? "未命名名片"
            let subtitle = [card.company, card.jobTitle]
                .compactMap { $0 }
                .joined(separator: " · ")

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 72, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(0.82)
            ]

            (title as NSString).draw(
                in: CGRect(x: 140, y: 240, width: size.width - 280, height: 100),
                withAttributes: titleAttributes
            )
            (subtitle as NSString).draw(
                in: CGRect(x: 140, y: 360, width: size.width - 280, height: 120),
                withAttributes: subtitleAttributes
            )
        }
    }
}
