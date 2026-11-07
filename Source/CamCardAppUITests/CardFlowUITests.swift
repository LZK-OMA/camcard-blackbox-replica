import XCTest

/// 端到端 UI 自动化：
/// 空态 → 扫描第一张名片 → 使用示例名片 → 确认保存 → 回到列表；
/// 然后验证「加入第一张名片后，卡片与悬浮扫描按钮是否还能点击」。
final class CardFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSampleCardFlowThenListRemainsInteractive() throws {
        let app = XCUIApplication()
        app.launch()

        // 1) 扫描入口：全新安装走空态按钮；已有数据则走悬浮按钮（兼容重复运行）。
        let scanFirst = app.buttons["扫描第一张名片"]
        if scanFirst.waitForExistence(timeout: 15) {
            attachScreenshot(name: "01-empty-state")
            scanFirst.tap()
        } else {
            let floatingEntry = app.buttons["扫描名片"]
            XCTAssertTrue(
                floatingEntry.waitForExistence(timeout: 15),
                "❌ 首屏既没有「扫描第一张名片」也没有悬浮「扫描名片」入口（启动异常？）"
            )
            attachScreenshot(name: "01-card-list-existing")
            floatingEntry.tap()
        }

        // 2) 相机页（模拟器无相机）→ 使用示例名片
        let sampleButton = app.buttons["使用示例名片"]
        XCTAssertTrue(sampleButton.waitForExistence(timeout: 20), "❌ 扫描页未出现「使用示例名片」按钮")
        attachScreenshot(name: "02-camera-degraded")
        sampleButton.tap()

        // 3) 校对页 → 手动调整名片边角（新增功能）→ 确认保存
        let saveButton = app.buttons["确认保存"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 30), "❌ 校对页未出现「确认保存」按钮")
        attachScreenshot(name: "03-correction")

        let manualCornerButton = app.buttons["手动调整名片边角"]
        XCTAssertTrue(
            manualCornerButton.waitForExistence(timeout: 10),
            "❌ 校对页缺少「手动调整名片边角」入口"
        )
        manualCornerButton.tap()

        XCTAssertTrue(
            app.navigationBars["调整名片边角"].waitForExistence(timeout: 10),
            "❌ 四角编辑器未出现"
        )
        attachScreenshot(name: "03b-quad-editor")

        // 真实拖拽左上角手柄：先确认手柄存在，再向外拖动。
        let topLeftHandle = app.descendants(matching: .any)
            .matching(identifier: "左上角")
            .firstMatch
        if topLeftHandle.waitForExistence(timeout: 5) {
            let start = topLeftHandle.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            let destination = topLeftHandle.coordinate(
                withNormalizedOffset: CGVector(dx: 2.6, dy: 2.6)
            )
            start.press(forDuration: 0.2, thenDragTo: destination)
        }

        app.buttons["完成调整边角"].tap()
        XCTAssertTrue(
            app.buttons["确认保存"].waitForExistence(timeout: 15),
            "❌ 完成手动校正后没有回到校对页"
        )
        attachScreenshot(name: "03c-after-manual-corners")
        app.buttons["确认保存"].tap()

        // 4) 等待回到列表，并确认新名片出现
        let cardButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "陈亦舟")
        ).firstMatch
        XCTAssertTrue(cardButton.waitForExistence(timeout: 30), "❌ 保存后没有回到名片夹/没有出现新名片")
        attachScreenshot(name: "04-card-list-after-save")

        // 5) 关键回归：保存后卡片是否还能点击进入详情
        XCTAssertTrue(cardButton.isHittable, "❌ 保存后卡片不可点击（isHittable == false）")
        cardButton.tap()

        let detailTitle = app.navigationBars["名片详情"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 15), "❌ 点击卡片后没有进入详情页")
        attachScreenshot(name: "05-detail")
        detailTitle.buttons.element(boundBy: 0).tap()

        // 6) 关键回归：保存后右下角悬浮「扫描名片」是否还能点击
        let floatingScan = app.buttons["扫描名片"]
        XCTAssertTrue(floatingScan.waitForExistence(timeout: 15), "❌ 返回后找不到悬浮「扫描名片」按钮")
        XCTAssertTrue(floatingScan.isHittable, "❌ 悬浮扫描按钮不可点击（isHittable == false）")
        floatingScan.tap()

        XCTAssertTrue(
            app.buttons["使用示例名片"].waitForExistence(timeout: 20),
            "❌ 点击悬浮扫描按钮后没有拉起扫描页"
        )
        attachScreenshot(name: "06-scanner-again")
    }

    // MARK: - helpers

    private func attachScreenshot(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
