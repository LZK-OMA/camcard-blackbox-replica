//
//  ManualCardQuadTests.swift
//  CamCardClone
//
//  手动四角校正的值类型单元测试（无界面）：
//  - 默认四角有效且覆盖足够面积；
//  - 越界输入会被限制在 [0,1]；
//  - 自交 / 面积过小的四角会被判定无效。
//

import XCTest
import CoreGraphics

@testable import CamCardAppCore

final class ManualCardQuadTests: XCTestCase {

    func testDefaultQuad_isValid_andCoversImage() {
        let quad = ManualCardQuad.cardDefault

        XCTAssertTrue(quad.isValid)
        XCTAssertGreaterThan(quad.area, 0.5, "默认四角应覆盖画面大部分区域")
        XCTAssertEqual(quad.corners.count, 4)
    }

    func testInit_clampsOutOfBoundsPoints() {
        let quad = ManualCardQuad(
            topLeft: CGPoint(x: -0.5, y: -0.2),
            topRight: CGPoint(x: 1.7, y: 0.1),
            bottomRight: CGPoint(x: 1.2, y: 2.0),
            bottomLeft: CGPoint(x: 0.1, y: -3.0)
        )

        XCTAssertEqual(quad.topLeft, CGPoint(x: 0, y: 0))
        XCTAssertEqual(quad.topRight, CGPoint(x: 1, y: 0.1))
        XCTAssertEqual(quad.bottomRight, CGPoint(x: 1, y: 1))
        XCTAssertEqual(quad.bottomLeft, CGPoint(x: 0.1, y: 0))
    }

    func testSetCorner_clampsInput() {
        var quad = ManualCardQuad.cardDefault

        quad.setCorner(0, to: CGPoint(x: -1, y: 2))
        XCTAssertEqual(quad.topLeft, CGPoint(x: 0, y: 1))

        quad.setCorner(3, to: CGPoint(x: 0.42, y: 0.66))
        XCTAssertEqual(quad.bottomLeft, CGPoint(x: 0.42, y: 0.66))
    }

    func testSelfIntersectingQuad_isInvalid() {
        // 右上角与右下角互换 → 两条边相交。
        let quad = ManualCardQuad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.9, y: 0.1),
            bottomRight: CGPoint(x: 0.1, y: 0.9),
            bottomLeft: CGPoint(x: 0.9, y: 0.9)
        )

        XCTAssertFalse(quad.isValid)
    }

    func testTooSmallQuad_isInvalid() {
        let quad = ManualCardQuad(
            topLeft: CGPoint(x: 0.50, y: 0.50),
            topRight: CGPoint(x: 0.51, y: 0.50),
            bottomRight: CGPoint(x: 0.51, y: 0.51),
            bottomLeft: CGPoint(x: 0.50, y: 0.51)
        )

        XCTAssertLessThan(quad.area, 0.03)
        XCTAssertFalse(quad.isValid)
    }

    func testCornersInitializer_requiresFourPoints() {
        XCTAssertNil(ManualCardQuad(corners: [CGPoint(x: 0, y: 0)]))
        XCTAssertNotNil(ManualCardQuad(corners: ManualCardQuad.cardDefault.corners))
    }
}
