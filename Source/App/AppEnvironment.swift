//
//  AppEnvironment.swift
//  CamCardClone
//
//  依赖容器：生产环境使用磁盘 SwiftData 容器，Preview 使用内存容器 + Mock 数据。
//  所有服务在 @MainActor 上创建，避免 ModelContext 跨线程。
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppEnvironment {

    let container: ModelContainer
    let imageFileManager: CardImageFileManager
    let cardStore: CardStore
    let scanPipeline: CardScanPipeline
    let contactExporter: ContactExporter

    /// 持久化容器创建失败时的降级提示；正常启动为 nil。
    let startupWarning: String?

    init(
        container: ModelContainer,
        imageFileManager: CardImageFileManager = .shared,
        scanPipeline: CardScanPipeline = CardScanPipeline(),
        contactExporter: ContactExporter? = nil,
        startupWarning: String? = nil
    ) {
        self.container = container
        self.imageFileManager = imageFileManager
        self.scanPipeline = scanPipeline
        self.contactExporter = contactExporter ?? ContactExporter()
        self.startupWarning = startupWarning

        let repository = CardRepository(
            context: container.mainContext,
            imageFileManager: imageFileManager
        )
        self.cardStore = CardStore(
            repository: repository,
            imageFileManager: imageFileManager
        )
    }

    // MARK: - 生产

    /// 磁盘容器。失败时由 `makeForAppLaunch()` 降级到内存容器，避免启动即崩溃。
    static func live() throws -> AppEnvironment {
        let container = try CardRepository.makePersistentContainer()
        return AppEnvironment(container: container)
    }

    /// App 启动入口：优先磁盘，失败时使用内存容器并在名片夹顶部展示提示。
    static func makeForAppLaunch() -> AppEnvironment {
        do {
            return try live()
        } catch {
            let fallback: ModelContainer
            do {
                fallback = try CardRepository.makeInMemoryContainer()
            } catch {
                fatalError("无法创建内存 ModelContainer：\(error)")
            }
            return AppEnvironment(
                container: fallback,
                startupWarning: "本地存储初始化失败，本次数据仅保存在内存中。"
            )
        }
    }

    // MARK: - 生产（异步启动装配）

    /// App 启动入口（异步装配）：先在后台线程创建 SwiftData 容器，再回主线程组装依赖。
    ///
    /// 为什么必须是异步：
    /// - `ModelContainer` 的首次创建 / 打开磁盘 store / 轻量迁移都是**同步阻塞**操作。
    ///   旧实现把它放在 `App.init`（后来又挪进主线程的 `.task`）里执行，一旦耗时过长，
    ///   主 RunLoop 会被锁住：首帧无法提交，系统继续展示上一次的启动快照——
    ///   用户看到的是「名片夹」旧画面，但整屏没有任何手势响应，就像被一块透明玻璃挡住。
    /// - 这里把容器创建放进 `Task.detached`，主线程只负责渲染轻量加载页，始终可响应；
    ///   完成后回到 `@MainActor` 组装 `CardRepository` / `CardStore`
    ///   （`mainContext` 依旧只在主线程访问，SwiftData 线程模型不变）。
    ///
    /// 失败降级策略与同步版 `makeForAppLaunch()` 保持一致：磁盘容器失败 → 内存容器 + 提示。
    @MainActor
    static func makeForAppLaunchAsync() async throws -> AppEnvironment {
        #if DEBUG
        // UI 自动化测试启动参数：在创建容器之前清空磁盘数据，保证用例从确定状态开始。
        resetPersistentDataForUITestsIfNeeded()
        #endif

        do {
            let container = try await Task.detached(priority: .userInitiated) {
                try Self.makeDiskContainerOffMainActor()
            }.value
            return AppEnvironment(container: container)
        } catch {
            // 磁盘容器失败：降级到内存容器，保证 App 仍能进入名片夹（数据不落盘）。
            let fallback = try await Task.detached(priority: .userInitiated) {
                try Self.makeInMemoryContainerOffMainActor()
            }.value
            return AppEnvironment(
                container: fallback,
                startupWarning: "本地存储初始化失败，本次数据仅保存在内存中。"
            )
        }
    }

    /// 与 `CardRepository.makePersistentContainer()` 等价的磁盘容器配置，
    /// 但声明为 `nonisolated`，因此可以在后台任务中安全执行。
    nonisolated private static func makeDiskContainerOffMainActor() throws -> ModelContainer {
        do {
            // 首次启动 Application Support 可能不存在，提前创建，避免 SwiftData fopen 失败。
            let supportDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            // 目录创建失败不提前抛出，交给 ModelContainer 返回真实错误，由上层降级。
        }

        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: BusinessCard.self,
            configurations: configuration
        )
    }

    nonisolated private static func makeInMemoryContainerOffMainActor() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: BusinessCard.self,
            configurations: configuration
        )
    }

    // MARK: - UI 测试支持（仅 Debug）

#if DEBUG
    /// 由启动参数 `-uiTestResetData` 触发：删除磁盘 SwiftData store 与图片目录。
    /// 仅用于 UI 自动化测试，生产构建不包含。
    @MainActor
    static func resetPersistentDataForUITestsIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestResetData") else { return }

        let fileManager = FileManager.default
        if let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            for name in ["default.store", "default.store-shm", "default.store-wal"] {
                try? fileManager.removeItem(at: support.appendingPathComponent(name))
            }
        }
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(
                at: documents.appendingPathComponent("Cards", isDirectory: true)
            )
        }
    }
#endif

    // MARK: - Preview

#if DEBUG
    /// 带 3 条 Mock 名片的 Preview 环境。
    /// 图片写入 tmp/CamCardPreview，避免污染真实 Documents。
    static func preview() -> AppEnvironment {
        let previewRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CamCardPreview", isDirectory: true)
        let imageManager = CardImageFileManager(baseDirectory: previewRoot)

        let container: ModelContainer
        do {
            container = try MockCardDataHelper.makePreviewContainer(seedImages: true)
        } catch {
            container = try! CardRepository.makeInMemoryContainer()
        }

        return AppEnvironment(
            container: container,
            imageFileManager: imageManager
        )
    }
#endif
}
