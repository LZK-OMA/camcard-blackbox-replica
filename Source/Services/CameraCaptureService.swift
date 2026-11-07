//
//  CameraCaptureService.swift
//  CamCardClone
//
//  AVFoundation 相机服务。
//
//  职责边界：
//  - 只负责 AVCaptureSession 的配置、启停与单张照片拍摄；
//  - 不持有 SwiftUI 状态，不申请权限（权限由 ViewModel 驱动）；
//  - Session 的配置与 startRunning / stopRunning 全部在专用串行队列执行，
//    避免阻塞主线程，也避免 AVCaptureSession 的并发配置问题。
//
//  注意：真机必须在 Info.plist 提供 NSCameraUsageDescription，
//  否则系统会在首次请求权限时终止 App。
//

import AVFoundation
import Foundation
import UIKit

// MARK: - 错误

enum CameraCaptureError: LocalizedError {
    case noCamera
    case configurationFailed
    case sessionNotRunning
    case captureInProgress
    case captureFailed(Error)
    case photoDataUnavailable

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "当前设备没有可用相机"
        case .configurationFailed:
            return "相机初始化失败，请重试"
        case .sessionNotRunning:
            return "相机尚未准备好，请稍候"
        case .captureInProgress:
            return "正在拍摄，请稍候"
        case .captureFailed:
            return "拍摄失败，请重试"
        case .photoDataUnavailable:
            return "照片数据无效，请重拍"
        }
    }

    var underlyingError: Error? {
        switch self {
        case .captureFailed(let error):
            return error
        default:
            return nil
        }
    }
}

// MARK: - 相机服务

/// `@unchecked Sendable` 的前提：
/// - `session` 只在 sessionQueue 上配置 / 启停；
/// - `photoOutput` 只在 sessionQueue 上触发拍摄；
/// - 拍摄回调通过 NSLock 保护的 continuation 回到调用方。
final class CameraCaptureService: NSObject, @unchecked Sendable {

    // MARK: 公开状态

    /// 会话对象延迟创建：模拟器 / 无相机设备时完全不实例化 AVFoundation 对象，
    /// 避免这类对象在页面销毁时于主线程的析构路径上等待 AVFoundation 内部锁。
    lazy var session = AVCaptureSession()

    /// 当前相机是否支持闪光灯。
    ///
    /// 初始化时一次性读取、之后只读，因此**不需要任何锁**：
    /// 主线程（取景页 body 里的 `canUseFlash` / `flashIcon`）读取它时
    /// 不会触碰 pthread mutex，也就不会与 sessionQueue 形成互等。
    let hasFlash: Bool

    override init() {
        self.hasFlash = CameraCaptureService.cameraDevice?.hasFlash ?? false
        super.init()
    }

    /// 不需要申请权限即可探测硬件；模拟器返回 false。
    static var hasCameraDevice: Bool {
        cameraDevice != nil
    }

    static var cameraDevice: AVCaptureDevice? {
        AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: 私有状态

    private lazy var photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(
        label: "com.camcard.camera.session",
        qos: .userInitiated
    )
    private let captureLock = NSLock()
    private var captureContinuation: CheckedContinuation<UIImage, Error>?
    private var isConfigured = false

    // MARK: - 启停

    /// 配置（仅一次）并启动会话。
    func start() async throws {
        guard Self.hasCameraDevice else {
            throw CameraCaptureError.noCamera
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CameraCaptureError.configurationFailed)
                    return
                }

                do {
                    try self.configureIfNeeded()

                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 停止会话。异步派发到 sessionQueue，不阻塞主线程。
    /// 若此时仍有待回调的拍摄，主动结束 continuation，避免调用方永久挂起。
    func stop() {
        // 没有相机设备时从未创建 session，无需也不应触碰 AVFoundation。
        guard Self.hasCameraDevice else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.captureLock.lock()
            let pending = self.captureContinuation
            self.captureContinuation = nil
            self.captureLock.unlock()
            pending?.resume(throwing: CameraCaptureError.sessionNotRunning)

            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    // MARK: - 拍照

    /// 拍摄一张照片。返回的 UIImage 保留 EXIF orientation，由扫描流水线统一归一化。
    func capturePhoto(flashMode: AVCaptureDevice.FlashMode) async throws -> UIImage {
        guard Self.hasCameraDevice else {
            throw CameraCaptureError.noCamera
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CameraCaptureError.configurationFailed)
                    return
                }

                guard self.isConfigured, self.session.isRunning else {
                    continuation.resume(throwing: CameraCaptureError.sessionNotRunning)
                    return
                }

                self.captureLock.lock()
                if self.captureContinuation != nil {
                    self.captureLock.unlock()
                    continuation.resume(throwing: CameraCaptureError.captureInProgress)
                    return
                }
                self.captureContinuation = continuation
                self.captureLock.unlock()

                let settings = AVCapturePhotoSettings()
                if self.photoOutput.supportedFlashModes.contains(flashMode) {
                    settings.flashMode = flashMode
                }
                settings.photoQualityPrioritization = .quality
                if self.photoOutput.maxPhotoDimensions.width > 0 {
                    settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                }

                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: - 配置

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }

        guard let device = Self.cameraDevice else {
            throw CameraCaptureError.noCamera
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }

        // 上次配置失败可能留下半成品，重试前先清空。
        for input in session.inputs {
            session.removeInput(input)
        }
        if session.outputs.contains(where: { $0 === photoOutput }) {
            session.removeOutput(photoOutput)
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraCaptureError.configurationFailed
        }

        guard session.canAddInput(input) else {
            throw CameraCaptureError.configurationFailed
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            throw CameraCaptureError.configurationFailed
        }
        session.addOutput(photoOutput)

        // 名片场景不需要 48MP：优先选择不超过 12MP 的最大尺寸，兼顾清晰度与处理耗时。
        let supportedDimensions = device.activeFormat.supportedMaxPhotoDimensions
        let cappedDimensions = supportedDimensions.filter {
            Int($0.width) * Int($0.height) <= 12_000_000
        }
        let candidates = cappedDimensions.isEmpty ? supportedDimensions : cappedDimensions
        if let maxDimensions = candidates.max(by: {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }) {
            photoOutput.maxPhotoDimensions = maxDimensions
        }

        // 业务名片只支持竖屏取景，统一把预览与照片连接旋转到 90°。
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        isConfigured = true
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraCaptureService: AVCapturePhotoCaptureDelegate {

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let result: Result<UIImage, Error>

        if let error {
            result = .failure(CameraCaptureError.captureFailed(error))
        } else if let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) {
            result = .success(image)
        } else {
            result = .failure(CameraCaptureError.photoDataUnavailable)
        }

        captureLock.lock()
        let continuation = captureContinuation
        captureContinuation = nil
        captureLock.unlock()

        guard let continuation else { return }
        switch result {
        case .success(let image):
            continuation.resume(returning: image)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
