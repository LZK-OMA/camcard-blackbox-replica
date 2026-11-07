//
//  CameraCaptureViewModel.swift
//  CamCardClone
//
//  相机取景页 ViewModel：权限状态机、会话启停、闪光灯、拍摄与重拍。
//  拍摄得到的 UIImage 由 View 通过回调交给 CardScannerView 做 OCR / 校对。
//

import AVFoundation
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class CameraCaptureViewModel {

    // MARK: - 状态

    enum PermissionState: Equatable {
        case idle
        case requesting
        case authorized
        case denied
        case unavailable
    }

    private(set) var permission: PermissionState = .idle
    private(set) var isCapturing = false
    private(set) var isSessionRunning = false
    private(set) var capturedImage: UIImage?
    private(set) var capturedSource: CardSource = .camera

    var flashMode: AVCaptureDevice.FlashMode = .auto
    var errorMessage: String?

    // MARK: - 依赖

    private let service: CameraCaptureService
    @ObservationIgnored private var isPreparing = false
    @ObservationIgnored private var isStartingSession = false

    init(service: CameraCaptureService = CameraCaptureService()) {
        self.service = service
    }

    // MARK: - 派生状态

    var cameraSession: AVCaptureSession { service.session }

    var isReviewing: Bool { capturedImage != nil }

    var hasFlash: Bool { service.hasFlash }

    /// 有硬件但配置失败时，允许用户重试；模拟器无摄像头时不展示重试。
    var canRetryCamera: Bool { CameraCaptureService.hasCameraDevice }

    var canUseFlash: Bool {
        permission == .authorized && service.hasFlash && capturedImage == nil
    }

    var flashIcon: String {
        guard canUseFlash else { return "bolt.slash" }
        switch flashMode {
        case .auto: return "bolt.badge.a"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash"
        @unknown default: return "bolt.slash"
        }
    }

    var flashLabel: String {
        guard canUseFlash else { return "关闭" }
        switch flashMode {
        case .auto: return "自动"
        case .on: return "开启"
        case .off: return "关闭"
        @unknown default: return "关闭"
        }
    }

    // MARK: - 权限与会话

    /// 只探测硬件、不申请权限。相册优先入口在真机上不应被强行弹相机权限。
    func markCameraUnavailableIfNeeded() {
        guard capturedImage == nil else { return }
        if !CameraCaptureService.hasCameraDevice {
            permission = .unavailable
        }
    }

    /// 首次进入相机页时调用：检查硬件、申请权限并启动会话。
    func prepare() async {
        guard !isPreparing else { return }
        guard capturedImage == nil else { return }
        guard CameraCaptureService.hasCameraDevice else {
            permission = .unavailable
            return
        }
        if permission == .authorized, isSessionRunning { return }

        isPreparing = true
        defer { isPreparing = false }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .authorized
            await startSession()

        case .notDetermined:
            permission = .requesting
            let granted = await requestCameraAccess()
            guard !Task.isCancelled else { return }

            if granted {
                permission = .authorized
                await startSession()
            } else {
                permission = .denied
            }

        case .denied, .restricted:
            permission = .denied

        @unknown default:
            permission = .denied
        }
    }

    /// 从系统设置返回、App 回到前台时调用。相机已授权则自动恢复预览。
    func refreshPermission() async {
        guard capturedImage == nil else { return }
        guard CameraCaptureService.hasCameraDevice else {
            permission = .unavailable
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .authorized
            await startSession()

        case .denied, .restricted:
            permission = .denied

        case .notDetermined:
            await prepare()

        @unknown default:
            permission = .denied
        }
    }

    /// 停止会话。View 消失、进入后台或拍完进入确认状态时调用。
    func stop() {
        service.stop()
        isSessionRunning = false
    }

    private func startSession() async {
        guard permission == .authorized, !isSessionRunning, !isStartingSession else {
            return
        }

        isStartingSession = true
        defer { isStartingSession = false }

        do {
            try await service.start()

            guard !Task.isCancelled else {
                service.stop()
                return
            }
            isSessionRunning = true
            errorMessage = nil
        } catch CameraCaptureError.noCamera {
            permission = .unavailable
        } catch {
            permission = .unavailable
            errorMessage = error.localizedDescription
        }
    }

    private func requestCameraAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - 拍摄

    func capture() async {
        guard permission == .authorized,
              !isCapturing,
              capturedImage == nil,
              isSessionRunning else {
            return
        }

        isCapturing = true
        defer { isCapturing = false }

        do {
            let image = try await service.capturePhoto(flashMode: effectiveFlashMode)
            capturedImage = image
            capturedSource = .camera
            stop()
        } catch let error as CameraCaptureError {
            if case .noCamera = error {
                permission = .unavailable
            }
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 从相册选择后直接进入确认状态，不需要相机权限。
    func usePickedImage(_ image: UIImage) {
        stop()
        capturedImage = image
        capturedSource = .photoLibrary
        errorMessage = nil
    }

    func retake() {
        capturedImage = nil
        capturedSource = .camera
        Task { await prepare() }
    }

    /// 用户点击「使用照片」。返回图片与来源，交由扫描流程继续 OCR。
    func confirmSelection() -> (UIImage, CardSource)? {
        guard let capturedImage else { return nil }
        stop()
        return (capturedImage, capturedSource)
    }

    // MARK: - 闪光灯

    func cycleFlash() {
        guard canUseFlash else { return }
        switch flashMode {
        case .auto:
            flashMode = .on
        case .on:
            flashMode = .off
        case .off:
            flashMode = .auto
        @unknown default:
            flashMode = .auto
        }
    }

    private var effectiveFlashMode: AVCaptureDevice.FlashMode {
        guard service.hasFlash else { return .off }
        switch flashMode {
        case .auto, .on, .off: return flashMode
        @unknown default: return .off
        }
    }

    // MARK: - 辅助

    func reportImageLoadFailure(_ message: String) {
        errorMessage = message
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func dismissError() {
        errorMessage = nil
    }
}
