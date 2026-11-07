//
//  ManualCardQuad.swift
//  CamCardClone
//
//  手动四角校正的纯值类型。
//
//  坐标约定（与 UI 一致，别和 Vision 坐标系混淆）：
//  - 归一化到 [0, 1]；
//  - 原点在左上，x 向右、y 向下；
//  - 顺序：左上(TL) → 右上(TR) → 右下(BR) → 左下(BL)。
//
//  CardScanPipeline 在做透视校正前会把 y 轴翻转成 Core Image/Vision 的
//  「原点左下」坐标系。
//

import CoreGraphics
import Foundation

struct ManualCardQuad: Equatable, Sendable {

    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// 检测失败时的默认内缩矩形：整幅图内缩 6%，用户直接拖拽四角微调即可。
    /// （spec E-DET-001：未检测到边缘 → 降级原图 + 手动裁剪入口）
    static let cardDefault = ManualCardQuad(
        topLeft: CGPoint(x: 0.06, y: 0.08),
        topRight: CGPoint(x: 0.94, y: 0.08),
        bottomRight: CGPoint(x: 0.94, y: 0.92),
        bottomLeft: CGPoint(x: 0.06, y: 0.92)
    )

    var corners: [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    init(
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomRight: CGPoint,
        bottomLeft: CGPoint
    ) {
        self.topLeft = Self.clamped(topLeft)
        self.topRight = Self.clamped(topRight)
        self.bottomRight = Self.clamped(bottomRight)
        self.bottomLeft = Self.clamped(bottomLeft)
    }

    init?(corners: [CGPoint]) {
        guard corners.count == 4 else { return nil }
        self.init(
            topLeft: corners[0],
            topRight: corners[1],
            bottomRight: corners[2],
            bottomLeft: corners[3]
        )
    }

    // MARK: - 编辑

    /// 拖拽第 index 个角（0 左上 / 1 右上 / 2 右下 / 3 左下），坐标限制在图像内。
    mutating func setCorner(_ index: Int, to point: CGPoint) {
        let clamped = Self.clamped(point)
        switch index {
        case 0: topLeft = clamped
        case 1: topRight = clamped
        case 2: bottomRight = clamped
        case 3: bottomLeft = clamped
        default: break
        }
    }

    func clamped() -> ManualCardQuad {
        ManualCardQuad(
            topLeft: topLeft,
            topRight: topRight,
            bottomRight: bottomRight,
            bottomLeft: bottomLeft
        )
    }

    // MARK: - 几何校验

    /// 有符号面积；正数表示 TL→TR→BR→BL 的有效顺序（图像坐标系，y 向下）。
    var signedArea: CGFloat {
        let points = corners
        var sum: CGFloat = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            sum += current.x * next.y - next.x * current.y
        }
        return sum / 2
    }

    var area: CGFloat {
        abs(signedArea)
    }

    /// 四点能否构成有效名片四边形：
    /// - 都在图像范围内；
    /// - 面积 ≥ 图像 3%；
    /// - 顺序正确（非翻转）；
    /// - 四条边不自交、不过短。
    var isValid: Bool {
        let points = corners
        guard points.allSatisfy({ $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }) else {
            return false
        }
        guard signedArea >= 0.03 else { return false }

        // 对边是否相交（自交说明拖拽顺序错乱，透视校正结果会翻转）。
        guard !Self.segmentsIntersect(points[0], points[1], points[2], points[3]),
              !Self.segmentsIntersect(points[1], points[2], points[3], points[0]) else {
            return false
        }

        for index in 0..<4 {
            let a = points[index]
            let b = points[(index + 1) % 4]
            if hypot(a.x - b.x, a.y - b.y) < 0.05 {
                return false
            }
        }
        return true
    }

    // MARK: - 私有

    private static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
    }

    private static func segmentsIntersect(
        _ p1: CGPoint,
        _ p2: CGPoint,
        _ p3: CGPoint,
        _ p4: CGPoint
    ) -> Bool {
        func orientation(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Int {
            let value = (b.y - a.y) * (c.x - b.x) - (b.x - a.x) * (c.y - b.y)
            if abs(value) < 1e-9 { return 0 }
            return value > 0 ? 1 : 2
        }
        let o1 = orientation(p1, p2, p3)
        let o2 = orientation(p1, p2, p4)
        let o3 = orientation(p3, p4, p1)
        let o4 = orientation(p3, p4, p2)
        return o1 != o2 && o3 != o4
    }
}
