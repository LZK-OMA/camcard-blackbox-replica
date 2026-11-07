// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CamCardCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CamCardCore", targets: ["CamCardCore"])
    ],
    targets: [
        .target(
            name: "CamCardCore",
            path: "Source/CamCardCore"
        ),

        // 仅用于 macOS 无头测试的最小 UIKit 替身模块，
        // 让真实的 Store / 文件管理器可以在不启动模拟器的前提下编译执行。
        // 不参与 iOS App Target（App 使用 CamCardApp.xcodeproj 构建）。
        .target(
            name: "UIKit",
            path: "Source/Diagnostics/HeadlessFlowTests/Shim",
            sources: ["UIKit.swift"]
        ),

        // 可被 macOS 无头测试编译的 App 业务内核：
        // 模型 + 数据仓库 + 列表 ViewModel（不含任何 SwiftUI / UIKit 视图代码）。
        .target(
            name: "CamCardAppCore",
            dependencies: ["UIKit", "CamCardCore"],
            path: ".",
            sources: [
                "Source/Common/ManualCardQuad.swift",
                "Source/Models/BusinessCard.swift",
                "Source/Models/CardFormValues.swift",
                "Source/Models/ScanDraft.swift",
                "Source/Services/CardRepository.swift",
                "Source/Services/CardStore.swift",
                "Source/Services/CardImageFileManager.swift",
                "Source/Services/CardImageLoader.swift",
                "Source/Services/CardScanPipeline.swift",
                "Source/Services/ContactExporter.swift",
                "Source/ViewModels/CardListViewModel.swift",
                "Source/ViewModels/CardScannerViewModel.swift",
                "Source/ViewModels/CardCorrectionViewModel.swift",
                "Source/Diagnostics/HeadlessFlowTests/Stubs.swift",
                "Source/Diagnostics/HeadlessFlowTests/PackageTestSupport.swift"
            ]
        ),

        .testTarget(
            name: "CardInteractionFlowTests",
            dependencies: ["CamCardAppCore"],
            path: "Source/Tests/CardInteractionFlowTests"
        ),

        .testTarget(
            name: "ReferenceSuiteHeadlessTests",
            dependencies: ["CamCardAppCore", "CamCardCore"],
            path: "Source/Tests/ReferenceSuiteHeadlessTests",
            resources: [.copy("Fixtures")]
        ),

        .testTarget(
            name: "ReferenceSuiteEvaluationTests",
            dependencies: ["CamCardAppCore", "CamCardCore", "UIKit"],
            path: "Source/Tests/ReferenceSuiteEvaluationTests"
        ),

        .testTarget(
            name: "CamCardCoreTests",
            dependencies: ["CamCardCore"],
            path: "Source/Tests/CamCardCoreTests"
        )
    ]
)
