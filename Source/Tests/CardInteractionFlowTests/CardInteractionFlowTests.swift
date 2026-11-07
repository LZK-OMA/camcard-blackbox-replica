//
//  CardInteractionFlowTests.swift
//  CamCardClone
//
//  无界面依赖的交互状态单元测试：
//  - 动作 A：扫描入口（悬浮按钮 / 从相册导入）是否在主线程正确把 isScannerPresented 置为 true；
//  - 动作 B：卡片点击后，选中的名片是否进入导航路由状态；
//  - 动作 C：列表数据就绪后，ViewModel 是否处于空闲、可交互状态。
//
//  说明：CardListView 是 SwiftUI View，其 @State 只有在视图宿主中才会存在，
//  无法在无界面测试里实例化；因此把「扫描呈现 / 导航路由」状态抽到了
//  CardListViewModel（`testable seam`），View 直接驱动同一份状态。
//

import XCTest
import SwiftData

@testable import CamCardAppCore

final class CardInteractionFlowTests: XCTestCase {

    // MARK: - 测试夹具（真实 CardStore + 1 张真实名片）

    private struct Fixture {
        let root: URL
        let container: ModelContainer
        let store: CardStore
        let card: BusinessCard
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardInteractionFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try CardRepository.makeInMemoryContainer()
        let imageManager = CardImageFileManager(baseDirectory: root)
        let repository = CardRepository(
            context: container.mainContext,
            imageFileManager: imageManager
        )
        let store = CardStore(repository: repository, imageFileManager: imageManager)

        let card = BusinessCard(
            name: "陈亦舟",
            company: "星澜科技（深圳）有限公司",
            jobTitle: "产品总监",
            mobile: "13800001234",
            originalImageFilename: "fixture/original.heic",
            source: .manual
        )
        try repository.save(card)
        store.reload()

        return Fixture(root: root, container: container, store: store, card: card)
    }

    private func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    // MARK: - 动作 A：悬浮扫描按钮 → isScannerPresented == true（主线程）

    @MainActor
    func testA_floatingScanButtonSetsScannerPresentedOnMainThread() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let viewModel = CardListViewModel(store: fixture.store)
        XCTAssertTrue(Thread.isMainThread, "交互入口必须在主线程执行")
        XCTAssertFalse(viewModel.isScannerPresented, "初始状态不得已呈现扫描层")

        // 悬浮「扫描名片」按钮的动作：presentScanner(startsWithPhotoPicker: false)
        viewModel.presentScanner(startsWithPhotoPicker: false)

        XCTAssertTrue(
            viewModel.isScannerPresented,
            "❌ 卡在 isScannerPresented 未变为 true：扫描入口状态没有推进"
        )
        XCTAssertFalse(viewModel.startsWithPhotoPicker)
        XCTAssertFalse(viewModel.isScannerDismissScheduled)
        XCTAssertEqual(viewModel.cards.count, 1, "扫描入口不应影响列表数据")
    }

    // MARK: - 动作 A2：从相册导入 + 残留状态自愈

    @MainActor
    func testA_albumImportCarriesPickerFlagAndRecoversFromStuckState() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let viewModel = CardListViewModel(store: fixture.store)

        // 空态「从相册导入」
        viewModel.presentScanner(startsWithPhotoPicker: true)
        XCTAssertTrue(viewModel.isScannerPresented)
        XCTAssertTrue(viewModel.startsWithPhotoPicker, "相册入口必须携带 startsWithPhotoPicker = true")

        // 模拟 last presentation 残留 true：再次点击应先归零、随后自愈为 true
        viewModel.presentScanner(startsWithPhotoPicker: false)
        XCTAssertFalse(viewModel.isScannerPresented, "自愈分支必须先把残留的 true 归零")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(
            viewModel.isScannerPresented,
            "❌ 卡在自愈分支：isScannerPresented 没有在下一个主线程周期重新置为 true"
        )
    }

    // MARK: - 动作 B：卡片点击 → 选中名片进入导航路由

    @MainActor
    func testB_cardTapRoutesSelectedCardIntoNavigationState() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let viewModel = CardListViewModel(store: fixture.store)
        let card = try XCTUnwrap(viewModel.cards.first, "列表应至少有 1 张名片")
        XCTAssertTrue(Thread.isMainThread, "卡片点击必须在主线程执行")
        XCTAssertTrue(viewModel.route.isEmpty, "初始导航路由必须为空")

        // CardListRow 的点击动作（视图层实际调用）：viewModel.openDetail(cardID:)
        let routed = viewModel.openDetail(cardID: card.id)

        XCTAssertTrue(routed, "❌ 卡在 openDetail 返回值：点击没有写入导航路由")
        XCTAssertEqual(viewModel.route.count, 1, "导航路由应恰好有 1 个目的地")
        XCTAssertEqual(viewModel.route.first?.id, card.id)
        XCTAssertTrue(viewModel.route.first?.card === card, "❌ 卡在 route：路由没有携带被点击的那张名片")
    }

    // MARK: - 动作 C：列表就绪后必须处于空闲可交互态

    @MainActor
    func testC_listIsIdleAndInteractiveWhenCardsExist() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let viewModel = CardListViewModel(store: fixture.store)

        XCTAssertEqual(viewModel.cards.count, 1)
        XCTAssertEqual(viewModel.rows.count, 1, "列表渲染快照应与数据一致")
        XCTAssertEqual(viewModel.rows.first?.title, "陈亦舟")
        XCTAssertTrue(viewModel.hasAnyCards, "有名片时 hasAnyCards 必须为 true")
        XCTAssertFalse(viewModel.isFiltering, "无搜索/筛选时 isFiltering 必须为 false")
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertNil(viewModel.errorMessage, "加载成功后不得残留错误")
        XCTAssertEqual(viewModel.emptyStateKind, .none, "有数据时不得处于任何空态")
        XCTAssertTrue(viewModel.isAllTagsSelected)
        XCTAssertTrue(viewModel.allTags.isEmpty)

        // 交互状态必须干净，不会阻塞入口
        XCTAssertFalse(viewModel.isScannerPresented)
        XCTAssertFalse(viewModel.isScannerDismissScheduled)
        XCTAssertTrue(viewModel.route.isEmpty)
    }

    // MARK: - 动作 C2：搜索/筛选后状态仍然一致

    @MainActor
    func testC_searchAndFilterKeepConsistentState() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let viewModel = CardListViewModel(store: fixture.store)

        viewModel.query = "陈"
        viewModel.reload()
        XCTAssertEqual(viewModel.cards.count, 1)
        XCTAssertTrue(viewModel.isFiltering)

        viewModel.query = "不存在的名字"
        viewModel.reload()
        XCTAssertEqual(viewModel.cards.count, 0)
        XCTAssertEqual(viewModel.emptyStateKind, .noResults)

        viewModel.query = ""
        viewModel.reload()
        XCTAssertEqual(viewModel.cards.count, 1)
        XCTAssertEqual(viewModel.emptyStateKind, .none)
    }
}
