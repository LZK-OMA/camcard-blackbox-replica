//
//  CardImageFileManager.swift
//  CamCardClone
//
//  图片文件仓库：把 UIImage 写入沙盒 Documents/Cards/，并只向数据库返回相对路径。
//
//  关键设计（对应作业红线）：
//  - 绝对路径包含 App Container 的随机 UUID，重装 / 迁移后会失效；
//  - 因此数据库仅保存相对路径，每次读写时用「当前 Documents 根目录 + 相对路径」拼接；
//  - 写文件前先显式检查并创建 `Documents/Cards/<cardID>/`，解决
//    "fopen failed for data file: errno = 2 (No such file or directory)"；
//  - 生产链路的 UIImage 编解码与磁盘 IO 全部在后台队列异步执行，主线程只接收结果；
//  - 写文件使用 Data.write(.atomic)，避免进程被杀时留下半个文件；
//  - 读取时拒绝绝对路径、`..` 等穿越路径，避免越权访问。
//

import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - 图片种类

enum CardImageKind: String, Sendable {
    case original
    case processed
}

// MARK: - 错误

enum CardImageFileManagerError: LocalizedError {
    case invalidImage
    case imageEncodingFailed
    case invalidRelativePath(String)
    case directoryCreationFailed(Error)
    case writeFailed(Error)
    case deleteFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "图片内容无效，无法保存"
        case .imageEncodingFailed:
            return "图片编码失败，请重试"
        case .invalidRelativePath:
            return "图片路径无效"
        case .directoryCreationFailed:
            return "无法创建图片目录"
        case .writeFailed:
            return "图片写入失败，请重试"
        case .deleteFailed:
            return "图片删除失败，请重试"
        }
    }

    /// 供日志 / 诊断使用，不直接展示给用户。
    var underlyingError: Error? {
        switch self {
        case .directoryCreationFailed(let error),
             .writeFailed(let error),
             .deleteFailed(let error):
            return error
        case .invalidImage, .imageEncodingFailed, .invalidRelativePath:
            return nil
        }
    }
}

// MARK: - 文件管理器

/// 名片图片文件管理器。
///
/// 文件布局：
/// ```
/// Documents/
/// └── Cards/
///     └── <cardID>/
///         ├── original.heic   // 或 original.jpg（设备不支持 HEIC 编码时自动降级）
///         └── processed.heic
/// ```
/// 数据库保存的 `originalImageFilename` 形如 `"<cardID>/original.heic"`。
///
/// 本类型无可变状态，FileManager 的文件操作本身是线程安全的，因此标记为
/// `@unchecked Sendable`，允许从后台 actor 调用（图片编码 / 大文件 IO 不阻塞主线程）。
final class CardImageFileManager: @unchecked Sendable {

    static let shared = CardImageFileManager()

    /// 图片编码（HEIC / JPEG）与磁盘读写的专用后台串行队列。
    ///
    /// 生产的保存链路只通过 `saveOriginalAsync(_:cardID:)` 等方法调用这里，
    /// 保证大图编码、`Data.write` 与目录创建都不会占用主线程，
    /// 从而避免「保存名片后 UI 卡死」这一类主线程阻塞问题。
    private static let ioQueue = DispatchQueue(
        label: "com.camcard.image-file-manager.io",
        qos: .userInitiated
    )

    private let fileManager: FileManager
    private let baseDirectoryOverride: URL?

    /// - Parameters:
    ///   - fileManager: 便于测试注入。
    ///   - baseDirectory: 测试用根目录；生产环境传 nil，即使用 Documents。
    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectoryOverride = baseDirectory
    }

    /// 当前 App 容器的 `Documents/Cards` 目录。
    /// 每次访问都重新解析 Documents 根目录，因此 Container UUID 变化后仍然有效。
    var cardsDirectory: URL {
        let base = baseDirectoryOverride
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)

        return base.appendingPathComponent("Cards", isDirectory: true)
    }

    // MARK: - 写入（同步 / 仅 Preview、测试）

    /// 同步保存原图，返回相对路径（相对 `Documents/Cards/`）。
    ///
    /// ⚠️ 会同步执行 UIImage 编码与磁盘写入。仅供 SwiftUI Preview、
    /// 单元测试等非 UI 关键路径使用；App 内的名片保存请使用
    /// `saveOriginalAsync(_:cardID:)`，避免阻塞主线程。
    @discardableResult
    func saveOriginal(_ image: UIImage, cardID: UUID) throws -> String {
        try save(image, cardID: cardID, kind: .original)
    }

    /// 同步保存校正图，返回相对路径（相对 `Documents/Cards/`）。
    /// ⚠️ 同 `saveOriginal`：生产链路请使用 `saveProcessedAsync(_:cardID:)`。
    @discardableResult
    func saveProcessed(_ image: UIImage, cardID: UUID) throws -> String {
        try save(image, cardID: cardID, kind: .processed)
    }

    /// 保存图片。优先 HEIC（质量 0.9），设备不支持 HEIC 编码时自动降级为 JPEG。
    /// 返回值是唯一的持久化凭证，调用方应把它写入 BusinessCard。
    ///
    /// ⚠️ 同步实现，会阻塞当前线程；生产保存链路请使用 `saveAsync(_:cardID:kind:)`。
    @discardableResult
    func save(_ image: UIImage, cardID: UUID, kind: CardImageKind) throws -> String {
        try write(image, cardID: cardID, kind: kind)
    }

    // MARK: - 写入（异步 / 生产链路）

    /// 异步保存原图：目录创建、UIImage 编码与磁盘写入全部在后台队列执行。
    @discardableResult
    func saveOriginalAsync(_ image: UIImage, cardID: UUID) async throws -> String {
        try await saveAsync(image, cardID: cardID, kind: .original)
    }

    /// 异步保存校正图：目录创建、UIImage 编码与磁盘写入全部在后台队列执行。
    @discardableResult
    func saveProcessedAsync(_ image: UIImage, cardID: UUID) async throws -> String {
        try await saveAsync(image, cardID: cardID, kind: .processed)
    }

    /// 异步保存图片。返回相对路径（相对 `Documents/Cards/`）。
    ///
    /// 使用 `withCheckedThrowingContinuation` 把同步文件操作桥接到后台队列，
    /// 不会阻塞调用方（主线程）；也没有 semaphore / wait() 之类的同步等待。
    @discardableResult
    func saveAsync(_ image: UIImage, cardID: UUID, kind: CardImageKind) async throws -> String {
        try await runOnIOQueue {
            try self.write(image, cardID: cardID, kind: kind)
        }
    }

    /// 真正的写盘实现：写前显式创建目录，再编码、原子写入。
    /// 只能在 `ioQueue`（或非主线程）上调用。
    private func write(_ image: UIImage, cardID: UUID, kind: CardImageKind) throws -> String {
        guard image.size.width > 0, image.size.height > 0 else {
            throw CardImageFileManagerError.invalidImage
        }

        let directory = cardDirectory(for: cardID)
        try ensureDirectory(directory)

        let encoded = try encode(image)
        let filename = "\(kind.rawValue).\(encoded.fileExtension)"
        let fileURL = directory.appendingPathComponent(filename, isDirectory: false)

        do {
            // .atomic 会先写同目录临时文件再替换，避免 Kill App 时产生损坏图片。
            try encoded.data.write(to: fileURL, options: [.atomic])
        } catch {
            throw CardImageFileManagerError.writeFailed(error)
        }

        // 如果本次编码格式与历史文件不同（例如 HEIC → JPEG），删除旧扩展名文件，
        // 保证一个 kind 在目录中最多只有一个有效文件。
        removeStaleVariants(in: directory, kind: kind, keeping: encoded.fileExtension)

        return "\(cardID.uuidString)/\(filename)"
    }

    // MARK: - 读取

    /// 把数据库中的相对路径解析成当前沙盒下的绝对 URL。
    /// 非法路径（绝对路径、`..`、空串）返回 nil，绝不越出 Cards 目录。
    func imageURL(for relativePath: String) -> URL? {
        let raw = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasPrefix("/") else { return nil }

        var components = raw
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        // 容错：兼容历史上可能带 "Cards/" 前缀的相对路径。
        if components.first == "Cards" {
            components.removeFirst()
        }

        guard !components.isEmpty,
              components.allSatisfy({ component in
                  component != "." && component != ".." && !component.contains("\0")
              })
        else {
            return nil
        }

        var candidate = cardsDirectory
        for component in components {
            candidate.appendPathComponent(component)
        }

        let standardized = candidate.standardizedFileURL
        let root = cardsDirectory.standardizedFileURL
        guard standardized.path == root.path
            || standardized.path.hasPrefix(root.path + "/")
        else {
            return nil
        }
        return standardized
    }

    /// 根据相对路径安全读取图片；文件不存在或损坏时返回 nil，由 UI 展示占位图。
    func loadImage(named relativePath: String) -> UIImage? {
        guard let url = imageURL(for: relativePath),
              fileManager.fileExists(atPath: url.path)
        else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    /// 读取原始文件数据，便于分享 / 导出时避免重复解码。
    func imageData(named relativePath: String) -> Data? {
        guard let url = imageURL(for: relativePath),
              fileManager.fileExists(atPath: url.path)
        else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// 文件是否存在（用于 E-DB-002 修复流程）。
    func fileExists(named relativePath: String) -> Bool {
        guard let url = imageURL(for: relativePath) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: - 删除

    /// 删除单个图片文件。文件不存在时视为成功（幂等）。
    func deleteImage(named relativePath: String) throws {
        guard let url = imageURL(for: relativePath) else {
            throw CardImageFileManagerError.invalidRelativePath(relativePath)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return
        }

        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw CardImageFileManagerError.deleteFailed(error)
        }
    }

    /// 删除某张名片的整个图片目录（原图 + 校正图）。不存在时视为成功。
    /// 注意：5 秒「撤销删除」场景应在撤销窗口结束后再调用，避免提前删图。
    func deleteImages(for cardID: UUID) throws {
        let directory = cardDirectory(for: cardID)
        guard fileManager.fileExists(atPath: directory.path) else { return }

        do {
            try fileManager.removeItem(at: directory)
        } catch {
            throw CardImageFileManagerError.deleteFailed(error)
        }
    }

    /// 异步删除某张名片的整个图片目录，避免主线程做文件 IO。
    /// 保存失败回滚时使用，保证清理不会拖慢 UI。
    func deleteImagesAsync(for cardID: UUID) async throws {
        try await runOnIOQueue {
            try self.deleteImages(for: cardID)
        }
    }

    /// 清空全部名片图片（设置页「清空数据」使用）。
    func deleteAllImages() throws {
        let directory = cardsDirectory
        guard fileManager.fileExists(atPath: directory.path) else { return }

        do {
            try fileManager.removeItem(at: directory)
        } catch {
            throw CardImageFileManagerError.deleteFailed(error)
        }
    }

    /// 异步清空全部名片图片，避免主线程做文件 IO。
    func deleteAllImagesAsync() async throws {
        try await runOnIOQueue {
            try self.deleteAllImages()
        }
    }

    // MARK: - 私有实现

    /// 把同步文件操作派发到后台 IO 队列，并用 continuation 桥接回 async/await。
    /// 只做异步派发，不使用 semaphore / wait()，不会阻塞调用线程。
    private func runOnIOQueue<T: Sendable>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            Self.ioQueue.async { [operation] in
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func cardDirectory(for cardID: UUID) -> URL {
        cardsDirectory.appendingPathComponent(cardID.uuidString, isDirectory: true)
    }

    /// 写盘前显式检查并创建 `Documents/Cards/` 根目录与 `<cardID>/` 子目录。
    ///
    /// 这是 `fopen failed ... errno = 2 (No such file or directory)` 的根治点：
    /// 首次保存时 Documents 下可能还没有 `Cards` 目录，直接 fopen 必然失败。
    /// `createDirectory(withIntermediateDirectories: true)` 对已存在目录是幂等的，
    /// 这里仍先 `fileExists` 判断，既满足「写前必建目录」，也避免不必要的系统调用。
    private func ensureDirectory(_ directory: URL) throws {
        do {
            // 先确保根目录 `Documents/Cards` 存在（第一次保存时通常还不存在）。
            try createDirectoryIfNeeded(at: cardsDirectory)
            // 再确保 `<cardID>` 子目录存在。
            try createDirectoryIfNeeded(at: directory)
        } catch {
            throw CardImageFileManagerError.directoryCreationFailed(error)
        }
    }

    /// 显式检查目录；不存在时用 `withIntermediateDirectories: true` 创建。
    /// 注：`fileManager` 在生产环境就是 `FileManager.default`，测试可注入替身。
    private func createDirectoryIfNeeded(at directory: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func removeStaleVariants(
        in directory: URL,
        kind: CardImageKind,
        keeping fileExtension: String
    ) {
        for ext in ["heic", "jpg", "jpeg"] where ext != fileExtension {
            let staleURL = directory.appendingPathComponent(
                "\(kind.rawValue).\(ext)",
                isDirectory: false
            )
            if fileManager.fileExists(atPath: staleURL.path) {
                try? fileManager.removeItem(at: staleURL)
            }
        }
    }

    private struct EncodedImage {
        let data: Data
        let fileExtension: String
    }

    private func encode(_ image: UIImage) throws -> EncodedImage {
        // HEIC 体积更小，优先使用。
        if let cgImage = normalizedCGImage(from: image),
           let data = Self.heicData(from: cgImage) {
            return EncodedImage(data: data, fileExtension: "heic")
        }

        // 模拟器或旧设备可能不支持 HEIC 编码，降级为 JPEG。
        guard let data = image.jpegData(compressionQuality: 0.9), !data.isEmpty else {
            throw CardImageFileManagerError.imageEncodingFailed
        }
        return EncodedImage(data: data, fileExtension: "jpg")
    }

    /// 将 UIImage 的 EXIF 方向烘焙进像素，保证写入文件的图片方向正确。
    private func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }

        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        // 保留原始像素尺寸：UIImage.size 是 point，需乘以 scale 才是像素。
        let scale = max(image.scale, 1)
        let pixelSize = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
        return normalized.cgImage
    }

    private static func heicData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination), data.length > 0 else {
            return nil
        }
        return data as Data
    }
}
