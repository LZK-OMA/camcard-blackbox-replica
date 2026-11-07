//
//  TestRunner.swift
//  Diagnostics / HeadlessFlowTests
//
//  无头（无模拟器、无图形界面）逻辑测试：直接编译 App 中真实的
//  CardScannerViewModel / CardCorrectionViewModel / CardStore /
//  CardRepository / CardImageFileManager，跑完整的
//  「导入图片 → OCR(替身) → 生成草稿 → 校对页 save(card:) → 落盘 + 写库 → 刷新」链路，
//  并对每一步状态与耗时做断言；任何 await 永远不返回都会被看门狗捕获。
//

import CoreGraphics
import Darwin
import Foundation
import SwiftData
import UIKit

// MARK: - 结果统计

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ✅ \(name)")
    } else {
        let extra = detail()
        let line = extra.isEmpty ? name : "\(name) — \(extra)"
        failures.append(line)
        print("  ❌ \(line)")
    }
}

// MARK: - 替身

struct StubRecognizer: CardTextRecognizing {
    let lines: [OCRTextLine]
    let meanConfidence: Float

    func recognizeText(in image: UIImage) async throws -> OCRResult {
        OCRResult(lines: lines, meanConfidence: meanConfidence)
    }
}

struct FailingRecognizer: CardTextRecognizing {
    func recognizeText(in image: UIImage) async throws -> OCRResult {
        throw CardScanError.invalidImage
    }
}

struct PassthroughCorrector: CardRectangleCorrecting {
    func correct(_ image: UIImage) async -> CardCorrectionOutcome {
        CardCorrectionOutcome(
            originalImage: image,
            processedImage: image,
            didDetectCardBoundary: false,
            detectionConfidence: 0
        )
    }
}

// MARK: - 工具

let sampleRawText = """
星澜科技（深圳）有限公司
SHENZHEN XINGLAN TECHNOLOGY CO., LTD.
产品总监  陈亦舟
Mobile 138 0000 1234
Tel: 0755-0000 5678
E-mail: Chen.Yizhou@Example.com
www.example.com
深圳市南山区科苑南路 0000 号 8 栋 1201
"""

func makeImage(width: Int = 1200, height: Int = 760) -> UIImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return UIImage(cgImage: context.makeImage()!)
}

func makeOCRResult() -> OCRResult {
    let lines = sampleRawText
        .split(separator: "\n")
        .enumerated()
        .map { index, text in
            OCRTextLine(
                text: String(text),
                confidence: 0.94,
                boundingBox: CGRect(
                    x: 0.1,
                    y: 0.9 - Double(index) * 0.08,
                    width: 0.8,
                    height: 0.05
                )
            )
        }
    return OCRResult(lines: lines, meanConfidence: 0.94)
}

@MainActor
func waitUntil(
    _ timeout: TimeInterval = 10,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
func waitForScannerToSettle(_ scanner: CardScannerViewModel, timeout: TimeInterval = 10) async -> Bool {
    await waitUntil(timeout) { !scanner.isProcessing }
}

func measure<T>(_ label: String, _ operation: () async throws -> T) async rethrows -> T {
    let start = Date()
    defer {
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "  ⏱  %@: %.1f ms", label, ms))
    }
    return try await operation()
}

// MARK: - 环境

@MainActor
struct TestEnvironment {
    let root: URL
    /// ModelContext 不保证强引用 container；必须显式持有，否则 container 释放后
    /// 后续 fetch 会触发 SwiftData 内部 assert。
    let container: ModelContainer
    let imageFileManager: CardImageFileManager
    let repository: CardRepository
    let store: CardStore
    let pipeline: CardScanPipeline

    init(label: String) throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Shim? no: HeadlessFlowTests
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("tmp-\(label)", isDirectory: true)

        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let container = try CardRepository.makeInMemoryContainer()
        let imageManager = CardImageFileManager(baseDirectory: base)
        let repository = CardRepository(
            context: container.mainContext,
            imageFileManager: imageManager
        )

        self.root = base
        self.container = container
        self.imageFileManager = imageManager
        self.repository = repository
        self.store = CardStore(repository: repository, imageFileManager: imageManager)
        self.pipeline = CardScanPipeline(
            recognizer: StubRecognizer(lines: makeOCRResult().lines, meanConfidence: 0.94),
            corrector: PassthroughCorrector()
        )
    }

    init(imageFileManager: CardImageFileManager, repository: CardRepository, container: ModelContainer) {
        self.root = URL(fileURLWithPath: NSTemporaryDirectory())
        self.container = container
        self.imageFileManager = imageFileManager
        self.repository = repository
        self.store = CardStore(repository: repository, imageFileManager: imageFileManager)
        self.pipeline = CardScanPipeline(
            recognizer: StubRecognizer(lines: makeOCRResult().lines, meanConfidence: 0.94),
            corrector: PassthroughCorrector()
        )
    }
}

// MARK: - 测试用例

@MainActor
func testScanToReview() async throws {
    print("\n[1] 导入图片 → OCR → 生成草稿（CardScannerViewModel）")
    let env = try TestEnvironment(label: "scan")
    let scanner = CardScannerViewModel(pipeline: env.pipeline)

    check(scanner.isProcessing == false, "初始 isProcessing == false")
    check(scanner.reviewPresented == false, "初始 reviewPresented == false")

    scanner.process(image: makeImage(), source: .photoLibrary)
    check(scanner.isProcessing == true, "调用 process 后 isProcessing == true（进度覆盖层可见）")

    let settled = await waitForScannerToSettle(scanner)
    check(settled, "异步识别在超时前返回（isProcessing 恢复 false）")
    check(scanner.isProcessing == false, "识别完成后 isProcessing == false（进度覆盖层可消失）")
    check(scanner.reviewPresented == true, "识别完成后 reviewPresented == true（进入校对页）")
    check(scanner.stage == .ready, "识别完成后 stage == .ready", "实际 \(scanner.stage)")
    check(scanner.draft != nil, "draft 不为 nil")
    check(scanner.failure == nil, "无 failure")

    if let draft = scanner.draft {
        check(draft.fields.name == "陈亦舟", "解析姓名 == 陈亦舟", "实际 \(draft.fields.name)")
        check(draft.fields.mobile == "13800001234", "解析手机号归一化", "实际 \(draft.fields.mobile)")
        check(draft.originalImage.cgImage != nil, "草稿携带原图")
    }
}

@MainActor
func testScanFailureAndManualEntry() async throws {
    print("\n[2] OCR 失败 → 手动录入兜底（不得卡住 isProcessing）")
    _ = try TestEnvironment(label: "scan-failure")
    let pipeline = CardScanPipeline(
        recognizer: FailingRecognizer(),
        corrector: PassthroughCorrector()
    )
    let scanner = CardScannerViewModel(pipeline: pipeline)

    scanner.process(image: makeImage(), source: .camera)
    let settled = await waitForScannerToSettle(scanner)
    check(settled, "识别失败后 isProcessing 恢复 false")
    check(scanner.isProcessing == false, "失败路径 isProcessing == false")
    check(scanner.failure != nil, "失败路径产生 failure 弹窗数据")
    check(scanner.reviewPresented == false, "失败路径不 push 校对页")

    if let failure = scanner.failure {
        scanner.startManualEntry(from: failure)
        check(scanner.isProcessing == false, "手动录入后 isProcessing == false")
        check(scanner.reviewPresented == true, "手动录入后 reviewPresented == true")
        check(scanner.failure == nil, "手动录入后 failure 被清空（弹窗关闭）")
    }
}

@MainActor
func testSampleCardFlow() async throws {
    print("\n[3] 示例名片模拟拍摄 → 校对页（CardScannerViewModel.simulateCapture）")
    let env = try TestEnvironment(label: "sample")
    let scanner = CardScannerViewModel(pipeline: env.pipeline)

    scanner.simulateCapture()
    check(scanner.isProcessing == true, "simulateCapture 后 isProcessing == true")

    let settled = await waitForScannerToSettle(scanner)
    check(settled, "流水线在超时前结束")
    check(scanner.isProcessing == false, "isProcessing 恢复 false")
    check(scanner.reviewPresented == true, "reviewPresented == true")
    check(scanner.draft != nil, "draft 不为 nil（示例名片解析成功）")
}

@MainActor
func testImageFileManagerRoundTrip() async throws {
    print("\n[0] 图片落盘（CardImageFileManager.saveOriginalAsync / saveProcessedAsync）")
    let env = try TestEnvironment(label: "io")
    let image = makeImage()
    let cardID = UUID()

    let original = try await measure("saveOriginalAsync") {
        try await env.imageFileManager.saveOriginalAsync(image, cardID: cardID)
    }
    check(!original.isEmpty, "原图返回相对路径", original)
    check(env.imageFileManager.fileExists(named: original), "原图文件存在")

    let processed = try await measure("saveProcessedAsync") {
        try await env.imageFileManager.saveProcessedAsync(image, cardID: cardID)
    }
    check(env.imageFileManager.fileExists(named: processed), "校正图文件存在")

    let deleteStart = Date()
    try await env.imageFileManager.deleteImagesAsync(for: cardID)
    let deleteMS = Date().timeIntervalSince(deleteStart) * 1000
    print(String(format: "  ⏱  deleteImagesAsync: %.1f ms", deleteMS))
    check(!env.imageFileManager.fileExists(named: original), "删除后原图不存在")
}

@MainActor
func testCreateAndSave() async throws {
    print("\n[4] 校对页 save(card:)：图片落盘 + SwiftData 写入 + 列表刷新")
    let env = try TestEnvironment(label: "save")
    let scanner = CardScannerViewModel(pipeline: env.pipeline)
    scanner.process(image: makeImage(), source: .photoLibrary)
    _ = await waitForScannerToSettle(scanner)

    guard let draft = scanner.draft else {
        check(false, "无法获得草稿，后续保存用例跳过")
        return
    }

    let correction = CardCorrectionViewModel(mode: .create(draft), store: env.store)
    check(correction.isSaving == false, "保存前 isSaving == false")
    check(correction.isLoadingImages == false, "新建模式无需加载图片，isLoadingImages == false")

    let card: BusinessCard? = await measure("save()") {
        await correction.save()
    }

    check(card != nil, "save() 返回已保存名片（await 正常返回）")
    check(correction.isSaving == false, "保存结束后 isSaving 必须恢复 false（否则保存按钮永久禁用）")
    check(correction.errorMessage == nil, "保存成功时 errorMessage == nil")
    check(correction.showDuplicateWarning == false, "保存成功时重名弹窗标志为 false")
    check(env.store.cards.count == 1, "CardStore.cards 数量 == 1", "实际 \(env.store.cards.count)")
    check(env.store.revision >= 2, "revision 已递增（列表会刷新）", "实际 \(env.store.revision)")

    if let card {
        check(env.imageFileManager.fileExists(named: card.originalImageFilename), "原图已写入沙盒")
        check(card.originalImageFilename.hasPrefix(card.id.uuidString), "数据库只保存相对路径")
        if let processed = card.processedImageFilename {
            check(env.imageFileManager.fileExists(named: processed), "校正图已写入沙盒")
        }
        check(card.name == "陈亦舟", "姓名字段已入库", "实际 \(card.name ?? "nil")")
        check(card.mobile == "13800001234", "手机字段已入库", "实际 \(card.mobile ?? "nil")")
    }
}

@MainActor
func testDuplicateConfirmation() async throws {
    print("\n[5] 重复名片二次确认（showDuplicateWarning 必须能关闭）")
    let env = try TestEnvironment(label: "duplicate")
    let scanner = CardScannerViewModel(pipeline: env.pipeline)
    scanner.process(image: makeImage(), source: .photoLibrary)
    _ = await waitForScannerToSettle(scanner)

    guard let draft = scanner.draft else {
        check(false, "无法获得草稿，重复检测用例跳过")
        return
    }

    let first = CardCorrectionViewModel(mode: .create(draft), store: env.store)
    let firstCard = await first.save()
    check(firstCard != nil, "第一张名片保存成功")

    let second = CardCorrectionViewModel(mode: .create(draft), store: env.store)
    let duplicate = await measure("save() duplicate") {
        await second.save()
    }

    check(duplicate == nil, "重复时 save() 返回 nil 并等待确认")
    check(second.showDuplicateWarning == true, "重复时 showDuplicateWarning == true（弹出二次确认）")
    check(second.isSaving == false, "重复确认分支 isSaving == false（按钮不能卡在保存中）")

    second.dismissDuplicateWarning()
    check(second.showDuplicateWarning == false, "取消后 showDuplicateWarning == false（弹窗关闭）")

    let confirmed = await measure("confirmDuplicateSave()") {
        await second.confirmDuplicateSave()
    }
    check(confirmed != nil, "确认后仍然可以保存")
    check(second.showDuplicateWarning == false, "确认保存后弹窗标志为 false")
    check(second.isSaving == false, "确认保存后 isSaving == false")
    check(env.store.cards.count == 2, "重复确认后共 2 张名片", "实际 \(env.store.cards.count)")
}

@MainActor
func testSaveFailureRestoresState() async throws {
    print("\n[6] 保存失败（无效图片）→ 必须回滚状态而不是卡死")
    let env = try TestEnvironment(label: "save-failure")
    let draft = ScanDraft(
        originalImage: UIImage(),          // 空图片：编码必然失败
        processedImage: nil,
        rawText: sampleRawText,
        confidence: 0.9,
        didDetectCardBoundary: false,
        source: .photoLibrary,
        parsed: ParsedCardFields(name: "陈亦舟", company: "星澜科技"),
        warnings: []
    )

    let correction = CardCorrectionViewModel(mode: .create(draft), store: env.store)
    let card: BusinessCard? = await measure("save() failing") {
        await correction.save()
    }

    check(card == nil, "保存失败返回 nil")
    check(correction.isSaving == false, "失败后 isSaving 必须恢复 false")
    check(correction.errorMessage != nil, "失败后展示 errorMessage")
    check(correction.showDuplicateWarning == false, "失败后不残留重复弹窗")
    check(env.store.cards.isEmpty, "失败后不应写入任何名片")
}

@MainActor
func testConcurrentSaveIsIdempotent() async throws {
    print("\n[7] 连点保存（并发 save）→ 只写一次且 isSaving 恢复")
    let env = try TestEnvironment(label: "concurrent")
    let scanner = CardScannerViewModel(pipeline: env.pipeline)
    scanner.process(image: makeImage(), source: .photoLibrary)
    _ = await waitForScannerToSettle(scanner)

    guard let draft = scanner.draft else {
        check(false, "无法获得草稿，并发保存用例跳过")
        return
    }

    let correction = CardCorrectionViewModel(mode: .create(draft), store: env.store)

    async let first: BusinessCard? = correction.save()
    async let second: BusinessCard? = correction.save()
    let results = await [first, second]

    let succeeded = results.compactMap { $0 }
    check(succeeded.count == 1, "并发 save 只有一次真正写入", "成功次数 \(succeeded.count)")
    check(correction.isSaving == false, "并发 save 结束后 isSaving == false")
    check(env.store.cards.count == 1, "数据库中只有 1 张名片", "实际 \(env.store.cards.count)")
}

@MainActor
func testEditModeImageLoading() async throws {
    print("\n[8] 编辑模式异步加载图片（isLoadingImages 必须归位）")
    let env = try TestEnvironment(label: "edit")
    let scanner = CardScannerViewModel(pipeline: env.pipeline)
    scanner.process(image: makeImage(), source: .photoLibrary)
    _ = await waitForScannerToSettle(scanner)

    guard let draft = scanner.draft else {
        check(false, "无法获得草稿，编辑模式用例跳过")
        return
    }

    let createVM = CardCorrectionViewModel(mode: .create(draft), store: env.store)
    guard let card = await createVM.save() else {
        check(false, "无法创建名片，编辑模式用例跳过")
        return
    }

    let editVM = CardCorrectionViewModel(mode: .edit(card), store: env.store)
    check(editVM.isLoadingImages == true, "编辑模式初始展示图片 loading 占位（isLoadingImages == true）")

    await measure("loadImagesIfNeeded()") {
        await editVM.loadImagesIfNeeded()
    }

    check(editVM.isLoadingImages == false, "图片加载结束后 isLoadingImages 必须恢复 false")
    check(editVM.originalImage != nil, "编辑模式成功加载原图")
}

@MainActor
func testCancellationRecoversState() async throws {
    print("\n[9] 处理中取消（cancelCurrentTask）→ 覆盖层必须消失")
    let env = try TestEnvironment(label: "cancel")
    let scanner = CardScannerViewModel(pipeline: env.pipeline)

    scanner.simulateCapture()
    check(scanner.isProcessing == true, "开始模拟拍摄 isProcessing == true")
    scanner.cancelCurrentTask()
    check(scanner.isProcessing == false, "取消后 isProcessing == false")

    try? await Task.sleep(for: .milliseconds(120))
    check(scanner.isProcessing == false, "取消后异步任务不得把 isProcessing 重新置回 true")
}

@MainActor
func testSwiftDataDirect() async throws {
    print("\n[11] SwiftData 直接落库（隔离定位）")
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent(".build/tmp-swiftdata-direct", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let imageManager = CardImageFileManager(baseDirectory: dir)

    print("  · makeInMemoryContainer")
    let container = try CardRepository.makeInMemoryContainer()
    print("  · context")
    let repo = CardRepository(context: container.mainContext, imageFileManager: imageManager)
    print("  · fetchAll (1)")
    let r1 = try repo.fetchAll()
    print("  · fetchAll count = \(r1.count)")
    print("  · store init")
    let env = TestEnvironment(imageFileManager: imageManager, repository: repo, container: container)
    print("  · fetchAll")
    let before = try env.repository.fetchAll()
    check(before.isEmpty, "初始无卡片")

    print("  · pre-fetch")
    let prefetched = try env.repository.fetchAll()
    print("  · pre-fetch count = \(prefetched.count)")

    print("  · BusinessCard init")
    let card = BusinessCard(originalImageFilename: "UUID/original.jpg")
    card.name = "陈亦舟"
    card.company = "星澜科技"

    print("  · validateForSaving")
    try card.validateForSaving()
    check(true, "validateForSaving 通过")

    print("  · repository.save")
    try env.repository.save(card)
    check(true, "repository.save 返回")

    print("  · fetch count")
    let after = try env.repository.fetchAll()
    check(after.count == 1, "落库后 1 张", "实际 \(after.count)")

    print("  · store.reload")
    env.store.reload()
    check(env.store.cards.count == 1, "Store 刷新后 1 张", "实际 \(env.store.cards.count)")
}

@MainActor
func testCreateCardDirect() async throws {
    print("\n[12] CardStore.createCard 直调（隔离 ViewModel）")
    let env = try TestEnvironment(label: "create-card-direct")
    let image = makeImage()

    print("  · 构造 ScanDraft")
    let draft = ScanDraft(
        originalImage: image,
        processedImage: image,
        rawText: sampleRawText,
        confidence: 0.94,
        didDetectCardBoundary: true,
        source: .photoLibrary,
        parsed: ParsedCardFields(name: "陈亦舟", company: "星澜科技"),
        warnings: []
    )
    let values = CardFormValues(parsed: draft.parsed)

    print("  · await store.createCard")
    let card = try await env.store.createCard(from: draft, values: values)
    print("  · createCard 返回 \(card.id)")
    check(env.store.cards.count == 1, "落库 1 张", "实际 \(env.store.cards.count)")

    print("  · 重复 createCard")
    let second = try await env.store.createCard(from: draft, values: values)
    check(env.store.cards.count == 2, "第二张落库", "实际 \(env.store.cards.count) / \(second.id)")
}

@MainActor
func testCreateCardStepsInline() async throws {
    print("\n[13] createCard 内部步骤拆解（进一步隔离）")
    let env = try TestEnvironment(label: "create-card-steps")
    let image = makeImage()
    let cardID = UUID()

    print("  · saveOriginalAsync")
    let originalPath = try await env.imageFileManager.saveOriginalAsync(image, cardID: cardID)
    print("  · saveOriginalAsync 返回 \(originalPath)")

    print("  · saveProcessedAsync")
    let processedPath = try await env.imageFileManager.saveProcessedAsync(image, cardID: cardID)
    print("  · saveProcessedAsync 返回 \(processedPath)")

    print("  · BusinessCard init")
    let card = BusinessCard(
        id: cardID,
        originalImageFilename: originalPath,
        processedImageFilename: processedPath,
        source: .photoLibrary
    )

    print("  · values.apply")
    var values = CardFormValues()
    values.name = "陈亦舟"
    values.company = "星澜科技"
    values.apply(to: card)

    print("  · validateForSaving")
    try card.validateForSaving()

    print("  · repository.save")
    try env.repository.save(card)
    print("  · repository.save 返回")

    print("  · store.reload")
    env.store.reload()
    check(env.store.cards.count == 1, "落库 1 张", "实际 \(env.store.cards.count)")
}

@MainActor
func testRepositorySaveWithoutImages() async throws {
    print("\n[14] repository.save（不带图片落盘）")
    let env = try TestEnvironment(label: "save-no-images")

    print("  · pre-fetch")
    let prefetched = try env.repository.fetchAll()
    print("  · pre-fetch count = \(prefetched.count)")

    print("  · BusinessCard init")
    let card = BusinessCard(originalImageFilename: "UUID/original.jpg")
    card.name = "陈亦舟"
    card.company = "星澜科技"

    print("  · validateForSaving")
    try card.validateForSaving()

    print("  · repository.save")
    try env.repository.save(card)
    print("  · repository.save 返回")
    let stored = try env.repository.fetchAll()
    check(stored.count == 1, "落库 1 张")
}

// MARK: - 入口

@main
struct HeadlessFlowTests {

    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        print("[boot] harness start")

        if false { // 调试挂钩已移除：不使用 lldb / 信号处理 / 同步等待
            let symbols = Thread.callStackSymbols.joined(separator: "\n")
            let message = "\n*** SIGTRAP caught ***\n\(symbols)\n"
            message.withCString { fputs($0, stderr) }
            exit(99)
        }
        let watchdog = Task.detached(priority: .high) {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            fputs(
                "\n❌ 看门狗超时：有 MainActor 异步任务 30s 内没有返回（疑似 await 永久挂起 / 主线程死锁）。\n",
                stderr
            )
            exit(2)
        }

        print("=== CamCard 无头逻辑测试（macOS，无模拟器 / 无图形界面）===")
        print("真实源码类型：CardScannerViewModel / CardCorrectionViewModel / CardStore / CardImageFileManager")

        await runAll()

        watchdog.cancel()

        print("\n=== 结果：\(checks - failures.count)/\(checks) 项通过 ===")
        if failures.isEmpty {
            print("✅ 全部通过")
            exit(0)
        } else {
            print("❌ 失败项：")
            for failure in failures {
                print("   - \(failure)")
            }
            exit(1)
        }
    }

    @MainActor
    static func runAll() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("图片落盘", testImageFileManagerRoundTrip),
            ("扫描→校对", testScanToReview),
            ("OCR失败兜底", testScanFailureAndManualEntry),
            ("示例名片", testSampleCardFlow),
            ("保存", testCreateAndSave),
            ("重复确认", testDuplicateConfirmation),
            ("保存失败回滚", testSaveFailureRestoresState),
            ("并发保存", testConcurrentSaveIsIdempotent),
            ("编辑图片加载", testEditModeImageLoading),
            ("取消恢复", testCancellationRecoversState),
            ("SwiftData直接落库", testSwiftDataDirect),
            ("createCard直调", testCreateCardDirect),
            ("createCard步骤", testCreateCardStepsInline),
            ("无图片落库", testRepositorySaveWithoutImages)
        ]

        let only = CommandLine.arguments.dropFirst().first
        for (index, item) in tests.enumerated() where only == nil || only == String(index + 1) {
            let (name, test) = item
            do {
                try await test()
            } catch {
                check(false, "\(name) 抛出未捕获错误：\(error)")
            }
        }
    }
}
