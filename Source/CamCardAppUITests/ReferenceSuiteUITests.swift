//
//  ReferenceSuiteUITests.swift
//  CamCardClone
//
//  T01–T20 Reference Test Suite 的 UI 部分（XCUITest，iPhone 15 模拟器）。
//
//  覆盖：T01, T02, T03, T12, T13, T14, T15, T16, T17, T18, T20
//  无头部分（T04–T11、T19）见 Tests/ReferenceSuiteHeadlessTests/。
//
//  每个用例通过启动参数 `-uiTestResetData` 清空本地数据，保证从确定状态开始；
//  T18 是例外：第一次启动清空，重启时不再带该参数，用于验证持久化。
//

import XCTest

final class ReferenceSuiteUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 启动 / 通用操作

    private func launchApp(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = reset ? ["-uiTestResetData"] : []
        app.launch()
        return app
    }

    private func enterScanner(_ app: XCUIApplication) {
        let scanFirst = app.buttons["扫描第一张名片"]
        if scanFirst.waitForExistence(timeout: 15) {
            scanFirst.tap()
            return
        }
        let floating = app.buttons["扫描名片"]
        XCTAssertTrue(floating.waitForExistence(timeout: 15), "❌ 列表页找不到扫描入口")
        floating.tap()
    }

    /// 扫描页 → 使用示例名片 → 校对页（模拟器无相机时的等价全链路）。
    private func sampleFlowToCorrection(_ app: XCUIApplication) {
        enterScanner(app)
        let sample = app.buttons["使用示例名片"]
        XCTAssertTrue(sample.waitForExistence(timeout: 20), "❌ 扫描页未出现「使用示例名片」")
        sample.tap()
        XCTAssertTrue(
            app.buttons["确认保存"].waitForExistence(timeout: 30),
            "❌ 示例名片没有进入校对页"
        )
    }

    private func cardRow(_ app: XCUIApplication, containing text: String = "陈亦舟") -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    private func saveAndRequireCard(
        _ app: XCUIApplication,
        containing text: String = "陈亦舟"
    ) {
        app.buttons["确认保存"].tap()
        XCTAssertTrue(
            cardRow(app, containing: text).waitForExistence(timeout: 30),
            "❌ 保存后列表没有出现名片"
        )
    }

    private func openDetail(_ app: XCUIApplication, containing text: String = "陈亦舟") {
        let row = cardRow(app, containing: text)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "❌ 列表中没有目标名片")
        row.tap()
        XCTAssertTrue(
            app.navigationBars["名片详情"].waitForExistence(timeout: 20),
            "❌ 没有进入名片详情页"
        )
    }

    private func backFromDetail(_ app: XCUIApplication) {
        app.navigationBars["名片详情"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.navigationBars["名片夹"].waitForExistence(timeout: 15),
            "❌ 返回名片夹失败"
        )
    }

    private func openMoreMenu(_ app: XCUIApplication) {
        let menuButton = app.buttons["更多操作"].firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10), "❌ 找不到更多操作菜单")
        // 导航栏的 SwiftUI Menu 在部分 iOS 版本上无法通过 AX 滚动/点击，使用坐标点击兜底。
        menuButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // MARK: - T01 首次启动与空态

    func test_T01_firstLaunch_showsEmptyState() {
        let app = launchApp()

        XCTAssertTrue(
            app.staticTexts["还没有名片"].waitForExistence(timeout: 20),
            "❌ T01：首次启动没有展示空名片夹状态"
        )
        XCTAssertTrue(app.buttons["扫描第一张名片"].exists, "❌ T01：缺少「扫描第一张名片」入口")
        XCTAssertTrue(app.buttons["从相册导入"].exists, "❌ T01：缺少「从相册导入」入口")
        XCTAssertTrue(app.textFields["搜索名片"].exists, "❌ T01：缺少搜索框")
    }

    // MARK: - T02 进入扫描页

    func test_T02_homeToScanner() {
        let app = launchApp()
        enterScanner(app)

        XCTAssertTrue(
            app.buttons["使用示例名片"].waitForExistence(timeout: 20),
            "❌ T02：没有进入扫描/拍摄页面"
        )
        XCTAssertTrue(app.buttons["关闭相机"].exists, "❌ T02：扫描页缺少关闭入口")
    }

    // MARK: - T03 相机权限/硬件不可用时的降级行为

    func test_T03_cameraUnavailable_degradedPageWithFallbacks() {
        let app = launchApp()
        enterScanner(app)

        // 模拟器没有摄像头：App 应进入「无可用相机」降级页，并提供相册/示例名片兜底。
        // 真机权限允许/拒绝的系统弹窗属于手工验证项，见课程报告。
        XCTAssertTrue(
            app.staticTexts["当前设备没有可用相机"].waitForExistence(timeout: 20),
            "❌ T03：无相机设备时没有展示降级页"
        )
        XCTAssertTrue(app.buttons["从相册导入"].exists, "❌ T03：降级页缺少相册入口")
        XCTAssertTrue(app.buttons["使用示例名片"].exists, "❌ T03：降级页缺少示例名片入口")
    }

    // MARK: - T04 拍摄 → 识别流程

    func test_T04_capture_entersRecognitionFlow() {
        let app = launchApp()
        enterScanner(app)

        // 模拟器无相机：使用示例名片走同一条识别/校对流水线；真机走拍摄按钮。
        if app.buttons["使用示例名片"].waitForExistence(timeout: 15) {
            app.buttons["使用示例名片"].tap()
        } else {
            app.buttons["拍摄"].tap()
        }

        XCTAssertTrue(
            app.buttons["确认保存"].waitForExistence(timeout: 30),
            "❌ T04：拍摄后没有进入识别/校对流程"
        )
    }

    // MARK: - T05 相册导入入口

    func test_T05_photoImport_opensScannerWithPickerPath() {
        let app = launchApp()

        let importButton = app.buttons["从相册导入"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 15), "❌ T05：空态缺少相册入口")
        importButton.tap()

        // 相册选择器是系统组件；这里验证 App 正确进入了「以相册为首屏」的扫描流程。
        // 导入后的识别链路（.photoLibrary 来源）由 T04 + 无头 T05 覆盖。
        XCTAssertTrue(
            app.buttons["关闭相机"].waitForExistence(timeout: 20),
            "❌ T05：从相册导入没有打开扫描页"
        )
    }

    // MARK: - T12 保存后回到列表并出现新名片

    func test_T12_save_returnsToListWithNewCard() {
        let app = launchApp()
        sampleFlowToCorrection(app)
        saveAndRequireCard(app)

        XCTAssertTrue(
            app.navigationBars["名片夹"].waitForExistence(timeout: 15),
            "❌ T12：保存后没有回到名片夹"
        )
    }

    // MARK: - T13 详情页展示全部字段

    func test_T13_detail_showsSavedFields() {
        let app = launchApp()
        sampleFlowToCorrection(app)
        saveAndRequireCard(app)
        openDetail(app)

        XCTAssertTrue(app.staticTexts["陈亦舟"].waitForExistence(timeout: 10), "❌ T13：缺少姓名")
        XCTAssertTrue(app.staticTexts["星澜科技（深圳）有限公司"].waitForExistence(timeout: 5), "❌ T13：缺少公司")
        XCTAssertTrue(app.staticTexts["产品总监"].waitForExistence(timeout: 5), "❌ T13：缺少职位")

        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "13800001234")).firstMatch
                .waitForExistence(timeout: 5),
            "❌ T13：缺少手机号"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "chen.yizhou@example.com")).firstMatch
                .waitForExistence(timeout: 5),
            "❌ T13：缺少邮箱"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "example.com")).firstMatch
                .exists,
            "❌ T13：缺少网址"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "科苑南路")).firstMatch
                .waitForExistence(timeout: 5),
            "❌ T13：缺少地址"
        )
    }

    // MARK: - T14 编辑姓名并保存

    func test_T14_editName_updatesDetail() {
        let app = launchApp()
        sampleFlowToCorrection(app)
        saveAndRequireCard(app)
        openDetail(app)

        openMoreMenu(app)
        let editEntry = app.buttons["编辑字段"]
        XCTAssertTrue(editEntry.waitForExistence(timeout: 10), "❌ T14：详情页缺少编辑入口")
        editEntry.tap()

        XCTAssertTrue(
            app.buttons["保存修改"].waitForExistence(timeout: 20),
            "❌ T14：没有进入编辑页"
        )

        let clearName = app.buttons["清空姓名"]
        if clearName.waitForExistence(timeout: 5) {
            clearName.tap()
        }
        let nameField = app.textFields["请输入姓名"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "❌ T14：找不到姓名输入框")
        nameField.tap()
        nameField.typeText("测试改名")

        app.buttons["保存修改"].tap()

        XCTAssertTrue(
            app.staticTexts["测试改名"].waitForExistence(timeout: 20),
            "❌ T14：保存后详情页没有更新姓名"
        )
    }

    // MARK: - T15 搜索

    func test_T15_search_byNameOrCompany() {
        let app = launchApp()
        sampleFlowToCorrection(app)
        saveAndRequireCard(app)

        let searchField = app.textFields["搜索名片"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "❌ T15：缺少搜索框")

        searchField.tap()
        searchField.typeText("星澜")
        XCTAssertTrue(
            cardRow(app).waitForExistence(timeout: 15),
            "❌ T15：按公司关键字搜索不到名片"
        )

        let clearSearch = app.buttons["清除搜索"]
        if clearSearch.waitForExistence(timeout: 5) {
            clearSearch.tap()
        }

        searchField.tap()
        searchField.typeText("不存在的人")
        XCTAssertTrue(
            app.staticTexts["未找到相关名片"].waitForExistence(timeout: 15),
            "❌ T15：搜索无结果时没有展示空结果状态"
        )
    }

    // MARK: - T16 标签

    func test_T16_addTag_andFilterByTag() {
        let app = launchApp()
        sampleFlowToCorrection(app)
        saveAndRequireCard(app)
        openDetail(app)

        let addTagButton = app.buttons["添加标签"]
        XCTAssertTrue(addTagButton.waitForExistence(timeout: 10), "❌ T16：详情页缺少添加标签入口")
        addTagButton.tap()

        let tagNav = app.navigationBars["新增标签"]
        XCTAssertTrue(tagNav.waitForExistence(timeout: 15), "❌ T16：没有打开新增标签面板")

        let tagField = app.textFields["例如：客户 / 展会 / 合作伙伴"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 10), "❌ T16：找不到标签输入框")
        tagField.tap()
        tagField.typeText("回归测试")

        tagNav.buttons["添加"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["回归测试"].waitForExistence(timeout: 15),
            "❌ T16：标签添加后详情页没有展示"
        )

        backFromDetail(app)

        let tagChip = app.buttons["回归测试"]
        XCTAssertTrue(tagChip.waitForExistence(timeout: 15), "❌ T16：列表筛选栏没有出现新标签")
        tagChip.tap()
        XCTAssertTrue(
            cardRow(app).waitForExistence(timeout: 15),
            "❌ T16：按标签筛选后名片消失"
        )
    }

    // MARK: - T17 删除名片

    func test_T17_delete_removesCardFromList() {
        let app = launchApp()
        sampleFlowToCorrection(app)
        saveAndRequireCard(app)
        openDetail(app)

        openMoreMenu(app)
        let deleteEntry = app.buttons["删除名片"]
        XCTAssertTrue(deleteEntry.waitForExistence(timeout: 10), "❌ T17：详情页缺少删除入口")
        deleteEntry.tap()

        // 删除确认弹窗是一个以标题为 label 的 overlay，内部才有真正的「删除」按钮；
        // 页面底栏也有一个同名「删除」按钮（被弹窗盖住），不能直接用 app.buttons["删除"]。
        let deleteDialog = app.otherElements["删除这张名片？"].firstMatch
        XCTAssertTrue(
            deleteDialog.waitForExistence(timeout: 10),
            "❌ T17：没有出现删除确认弹窗"
        )
        let dialogDeleteButton = deleteDialog.buttons["删除"].firstMatch
        XCTAssertTrue(
            dialogDeleteButton.waitForExistence(timeout: 5),
            "❌ T17：确认弹窗里找不到「删除」按钮"
        )
        dialogDeleteButton.tap()

        XCTAssertTrue(
            app.staticTexts["还没有名片"].waitForExistence(timeout: 20),
            "❌ T17：删除后列表没有回到空态"
        )
    }

    // MARK: - T18 冷启动持久化

    func test_T18_persistence_survivesRelaunch() {
        let app = launchApp(reset: true)
        sampleFlowToCorrection(app)
        saveAndRequireCard(app)

        app.terminate()
        app.launchArguments = []   // 重启时不清空数据
        app.launch()

        XCTAssertTrue(
            cardRow(app).waitForExistence(timeout: 30),
            "❌ T18：Kill 后重启，名片丢失"
        )
        openDetail(app)
        XCTAssertTrue(
            app.staticTexts["陈亦舟"].waitForExistence(timeout: 10),
            "❌ T18：重启后详情页数据不完整"
        )
    }

    // MARK: - T20 异常路径

    func test_T20_exceptionPaths_cancelAndValidation() {
        let app = launchApp()

        // 1) 进入扫描页后直接关闭 → 回到空态。
        enterScanner(app)
        XCTAssertTrue(
            app.buttons["关闭相机"].waitForExistence(timeout: 20),
            "❌ T20：扫描页缺少关闭入口"
        )
        app.buttons["关闭相机"].tap()
        XCTAssertTrue(
            app.staticTexts["还没有名片"].waitForExistence(timeout: 20),
            "❌ T20：取消扫描后没有回到名片夹"
        )

        // 2) 清空必填字段后保存 → 展示校验错误，不得写库。
        sampleFlowToCorrection(app)
        openMoreMenu(app)
        let clearAll = app.buttons["清空全部字段"]
        XCTAssertTrue(clearAll.waitForExistence(timeout: 10), "❌ T20：缺少清空字段入口")
        clearAll.tap()

        app.buttons["确认保存"].tap()
        XCTAssertTrue(
            app.staticTexts["请至少填写姓名或公司"].waitForExistence(timeout: 15),
            "❌ T20：空字段提交没有展示校验错误"
        )
        XCTAssertTrue(
            app.buttons["确认保存"].exists,
            "❌ T20：校验失败后不应离开校对页"
        )
    }
}
