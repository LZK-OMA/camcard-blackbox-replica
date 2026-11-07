//
//  CameraCaptureView.swift
//  CamCardClone
//
//  AVFoundation 相机取景页。
//
//  覆盖作业「功能二」的全部交互：
//  - 实时相机预览 + 名片取景框；
//  - 权限申请 / 拒绝后的去设置引导；
//  - 闪光灯（自动 / 开 / 关）、拍摄按钮；
//  - 拍摄完成后的「重拍 / 使用照片」；
//  - 任意状态下都可切换到系统相册导入。
//
//  相机只负责产出 UIImage；OCR、人工校对与保存由 CardScannerView /
//  CardCorrectionView 继续完成，保持现有 MVVM 分层。
//

import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct CameraCaptureView: View {

    // MARK: - 依赖

    private let startsWithPhotoPicker: Bool
    private let onClose: () -> Void
    private let onImagePicked: (UIImage, CardSource) -> Void
    private let onUseSample: (() -> Void)?

    // MARK: - 状态

    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: CameraCaptureViewModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var didAutoPresentPicker = false
    @State private var isLoadingPickedImage = false
    @State private var isShowingHelp = false
    @State private var shouldResumeCameraAfterPicker = false
    @State private var isViewVisible = true

    init(
        startsWithPhotoPicker: Bool = false,
        onClose: @escaping () -> Void,
        onImagePicked: @escaping (UIImage, CardSource) -> Void,
        onUseSample: (() -> Void)? = nil
    ) {
        self.startsWithPhotoPicker = startsWithPhotoPicker
        self.onClose = onClose
        self.onImagePicked = onImagePicked
        self.onUseSample = onUseSample
        _viewModel = State(initialValue: CameraCaptureViewModel())
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .statusBarHidden(true)
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $pickerItem,
            matching: .images,
            preferredItemEncoding: .compatible
        )
        .onChange(of: pickerItem) { _, newValue in
            guard let newValue else { return }
            pickerItem = nil
            loadPickedImage(newValue)
        }
        .onChange(of: isPhotoPickerPresented) { oldValue, newValue in
            guard oldValue, !newValue else { return }
            scheduleCameraResumeAfterPickerDismiss()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // 系统相册仍在展示时不抢跑相机；关闭相册后由
                // scheduleCameraResumeAfterPickerDismiss() 决定是否恢复。
                guard !isPhotoPickerPresented else { break }
                Task { @MainActor in
                    await viewModel.refreshPermission()
                }
            case .background, .inactive:
                viewModel.stop()
            @unknown default:
                break
            }
        }
        .task {
            if startsWithPhotoPicker, !didAutoPresentPicker {
                didAutoPresentPicker = true
                viewModel.markCameraUnavailableIfNeeded()
                // fullScreenCover 的呈现动画通常需要 ~0.35-0.5s；过早请求 present
                // 会被 UIKit 丢弃，而 @State 已变成 true，导致之后所有「从相册导入」
                // 点击都无效（状态没有再次变化）。这里等转场稳定后再弹。
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, isViewVisible else { return }
                shouldResumeCameraAfterPicker = false
                if !isPhotoPickerPresented {
                    isPhotoPickerPresented = true
                }
            } else {
                await viewModel.prepare()
            }
        }
        .onAppear {
            isViewVisible = true
        }
        .onDisappear {
            isViewVisible = false
            // 页面销毁时复位相册弹层状态，避免标志残留 true 让下次进入的
            // 「从相册导入」变成死按钮。
            isPhotoPickerPresented = false
            pickerItem = nil
            viewModel.stop()
        }
        .alert(
            "相机提示",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.dismissError() } }
            )
        ) {
            Button("好", role: .cancel) {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("拍摄说明", isPresented: $isShowingHelp) {
            Button("好", role: .cancel) {}
        } message: {
            Text("将名片平放在光线均匀的桌面，把四个角对准取景框。拍摄后可重拍或从相册重新选择；所有识别均在本机完成。")
        }
    }

    // MARK: - 内容分发

    @ViewBuilder
    private var content: some View {
        if let image = viewModel.capturedImage {
            reviewView(image)
        } else {
            switch viewModel.permission {
            case .idle, .requesting:
                permissionRequestView
            case .authorized:
                cameraView
            case .denied:
                deniedView
            case .unavailable:
                unavailableView
            }
        }
    }

    // MARK: - 实时取景

    private var cameraView: some View {
        ZStack {
            CameraPreview(session: viewModel.cameraSession)
                .ignoresSafeArea()

            scrims

            VStack(spacing: 0) {
                topBar(
                    title: "拍摄名片",
                    subtitle: "自动校正 · 本地识别",
                    showsFlash: true
                )

                Spacer(minLength: 10)

                cardGuide

                Text("将名片放入框内，保持光线均匀")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.top, 14)

                Spacer(minLength: 10)

                cameraControls
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)

            if !viewModel.isSessionRunning {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("正在启动相机…")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(22)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.black.opacity(0.48))
                )
            }
        }
    }

    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.62), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 180)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 250)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var cardGuide: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            .overlay(
                ViewfinderCorners(cornerLength: 36)
                    .stroke(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.62)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                    .padding(10)
            )
            .aspectRatio(1.58, contentMode: .fit)
            .allowsHitTesting(false)
    }

    private var cameraControls: some View {
        HStack(alignment: .center) {
            cameraSideButton(title: "相册", systemImage: "photo.on.rectangle") {
                presentPhotoPicker(resumeCamera: true)
            }
            .disabled(viewModel.isCapturing)

            Spacer()

            shutterButton

            Spacer()

            cameraSideButton(title: "说明", systemImage: "questionmark.circle") {
                isShowingHelp = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func cameraSideButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.12))
                            .overlay(
                                Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                            )
                    )

                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.64))
            }
            .frame(width: 66)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var shutterButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { @MainActor in
                await viewModel.capture()
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.88), lineWidth: 3)
                    .frame(width: 78, height: 78)

                Circle()
                    .fill(.white)
                    .frame(width: 62, height: 62)

                if viewModel.isCapturing {
                    ProgressView()
                        .tint(.black.opacity(0.7))
                } else {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.78))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isSessionRunning || viewModel.isCapturing)
        .opacity(viewModel.isSessionRunning ? 1 : 0.45)
        .accessibilityLabel("拍摄")
        .accessibilityHint("拍下当前取景框中的名片")
    }

    // MARK: - 拍摄确认

    private func reviewView(_ image: UIImage) -> some View {
        VStack(spacing: 0) {
            topBar(
                title: "确认照片",
                subtitle: viewModel.capturedSource == .photoLibrary
                    ? "来自系统相册"
                    : "来自相机拍摄",
                showsFlash: false
            )

            Spacer(minLength: 8)

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
                .padding(.horizontal, 10)
                .shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 8)

            Spacer(minLength: 8)

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        viewModel.retake()
                    } label: {
                        Label("重拍", systemImage: "arrow.counterclockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                    .tint(.white)

                    Button {
                        if let (image, source) = viewModel.confirmSelection() {
                            onImagePicked(image, source)
                        }
                    } label: {
                        Label("使用照片", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                    .tint(AppTheme.accent)
                }

                Button {
                    presentPhotoPicker(resumeCamera: false)
                } label: {
                    Label("从相册重新选择", systemImage: "photo.on.rectangle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    // MARK: - 权限申请中

    private var permissionRequestView: some View {
        VStack(spacing: 0) {
            topBar(title: "拍摄名片", subtitle: nil, showsFlash: false)

            Spacer()

            VStack(spacing: 16) {
                if viewModel.permission == .requesting {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: "camera")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 84, height: 84)
                        .background(Circle().fill(.white.opacity(0.08)))
                }

                Text(viewModel.permission == .requesting
                     ? "请在系统弹窗中允许访问相机"
                     : "相机尚未开启")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("首次使用需要相机权限；你也可以直接从相册导入名片照片。")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)

                HStack(spacing: 10) {
                    Button {
                        presentPhotoPicker(resumeCamera: false)
                    } label: {
                        Label("从相册导入", systemImage: "photo.on.rectangle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(.white.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)

                    if viewModel.permission == .idle {
                        Button {
                            Task { @MainActor in
                                await viewModel.prepare()
                            }
                        } label: {
                            Label("开启相机", systemImage: "camera")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(.white.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - 权限被拒绝

    private var deniedView: some View {
        permissionStateView(
            icon: "camera.slash",
            title: "无法访问相机",
            message: "相机权限已被关闭。请前往「设置 → 名片全能王 → 相机」开启权限，或直接从相册导入名片照片。",
            primaryTitle: "去设置",
            primaryIcon: "gearshape",
            showsGalleryShortcut: true,
            primaryAction: {
                viewModel.openSettings()
            }
        )
    }

    // MARK: - 无可用相机

    private var unavailableView: some View {
        permissionStateView(
            icon: "camera.metering.unknown",
            title: "当前设备没有可用相机",
            message: "模拟器或受限设备无法使用相机。你可以从相册选择一张名片照片，或使用示例名片体验完整识别与校对流程。",
            primaryTitle: "从相册导入",
            primaryIcon: "photo.on.rectangle",
            showsGalleryShortcut: false,
            primaryAction: {
                presentPhotoPicker(resumeCamera: false)
            },
            retryAction: viewModel.canRetryCamera
                ? {
                    Task { @MainActor in
                        await viewModel.prepare()
                    }
                }
                : nil
        )
    }

    private func permissionStateView(
        icon: String,
        title: String,
        message: String,
        primaryTitle: String,
        primaryIcon: String,
        showsGalleryShortcut: Bool,
        primaryAction: @escaping () -> Void,
        retryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 0) {
            topBar(title: "拍摄名片", subtitle: nil, showsFlash: false)

            Spacer()

            VStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 92, height: 92)
                    .background(
                        Circle().fill(.white.opacity(0.08))
                    )

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)

                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.58))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 26)
                }

                VStack(spacing: 10) {
                    Button(action: primaryAction) {
                        Label(primaryTitle, systemImage: primaryIcon)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                    .tint(AppTheme.accent)

                    if showsGalleryShortcut {
                        Button {
                            presentPhotoPicker(resumeCamera: false)
                        } label: {
                            Label("从相册导入", systemImage: "photo.on.rectangle")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 14))
                        .tint(.white)
                    }

                    if let retryAction {
                        Button(action: retryAction) {
                            Label("重试相机", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.82))
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                    }

                    if let onUseSample {
                        Button {
                            onUseSample()
                        } label: {
                            Label("使用示例名片", systemImage: "wand.and.stars")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.68))
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 6)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - 顶部栏

    private func topBar(
        title: String,
        subtitle: String?,
        showsFlash: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.12))
                            .overlay(
                                Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭相机")

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.50))
                }
            }

            Spacer(minLength: 0)

            if showsFlash {
                Button {
                    viewModel.cycleFlash()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: viewModel.flashIcon)
                            .font(.system(size: 15, weight: .semibold))
                        Text(viewModel.flashLabel)
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(.white.opacity(viewModel.canUseFlash ? 0.14 : 0.06))
                            .overlay(
                                Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canUseFlash)
                .opacity(viewModel.canUseFlash ? 1 : 0.42)
                .accessibilityLabel("闪光灯，当前\(viewModel.flashLabel)")
            } else {
                Color.clear
                    .frame(width: 44, height: 44)
            }
        }
    }

    // MARK: - 相册

    private func loadPickedImage(_ item: PhotosPickerItem) {
        isLoadingPickedImage = true

        Task { @MainActor in
            defer { isLoadingPickedImage = false }

            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    viewModel.reportImageLoadFailure("所选图片无法读取，请换一张试试")
                    return
                }

                // 相册原图可能有数千万像素，解码放到后台，避免卡住取景页。
                let decoded = await Task.detached(priority: .userInitiated) {
                    UIImage(data: data)
                }.value

                guard !Task.isCancelled, isViewVisible else { return }
                guard let image = decoded else {
                    viewModel.reportImageLoadFailure("所选图片无法解码，请换一张试试")
                    return
                }
                viewModel.usePickedImage(image)
            } catch {
                viewModel.reportImageLoadFailure(error.localizedDescription)
            }
        }
    }

    private func presentPhotoPicker(resumeCamera: Bool) {
        shouldResumeCameraAfterPicker = resumeCamera

        guard isPhotoPickerPresented else {
            isPhotoPickerPresented = true
            return
        }

        // 自愈：标志为 true 但系统弹层实际没弹出来（present 被 UIKit 丢弃）时，
        // 单写 true 不会触发任何变化，用户会看到「点了导入没反应」。
        isPhotoPickerPresented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            isPhotoPickerPresented = true
        }
    }

    /// 仅当相册是从「实时取景」打开时，关闭后才恢复相机。
    /// 从权限页 / 无相机页打开相册时，取消选择不应反向触发相机权限。
    /// 350ms 缓冲用于等待「已选图片」的异步加载。
    private func scheduleCameraResumeAfterPickerDismiss() {
        let shouldResume = shouldResumeCameraAfterPicker
        shouldResumeCameraAfterPicker = false
        guard shouldResume else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, isViewVisible else { return }
            guard viewModel.capturedImage == nil, !isLoadingPickedImage else { return }
            await viewModel.prepare()
        }
    }
}

// MARK: - 相机预览

private struct CameraPreview: UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.updateRotation()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.previewLayer.videoGravity = .resizeAspectFill
        uiView.updateRotation()
    }

    final class PreviewView: UIView {

        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            guard let layer = layer as? AVCaptureVideoPreviewLayer else {
                fatalError("PreviewView 的 layer 必须是 AVCaptureVideoPreviewLayer")
            }
            return layer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateRotation()
        }

        func updateRotation() {
            guard let connection = previewLayer.connection else { return }
            // 业务只支持竖屏名片。
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}

// MARK: - 取景框四角

private struct ViewfinderCorners: Shape {

    let cornerLength: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset: CGFloat = 1.5

        let topLeft = CGPoint(x: rect.minX + inset, y: rect.minY + inset)
        let topRight = CGPoint(x: rect.maxX - inset, y: rect.minY + inset)
        let bottomLeft = CGPoint(x: rect.minX + inset, y: rect.maxY - inset)
        let bottomRight = CGPoint(x: rect.maxX - inset, y: rect.maxY - inset)

        path.move(to: CGPoint(x: topLeft.x, y: topLeft.y + cornerLength))
        path.addLine(to: topLeft)
        path.addLine(to: CGPoint(x: topLeft.x + cornerLength, y: topLeft.y))

        path.move(to: CGPoint(x: topRight.x - cornerLength, y: topRight.y))
        path.addLine(to: topRight)
        path.addLine(to: CGPoint(x: topRight.x, y: topRight.y + cornerLength))

        path.move(to: CGPoint(x: bottomLeft.x, y: bottomLeft.y - cornerLength))
        path.addLine(to: bottomLeft)
        path.addLine(to: CGPoint(x: bottomLeft.x + cornerLength, y: bottomLeft.y))

        path.move(to: CGPoint(x: bottomRight.x - cornerLength, y: bottomRight.y))
        path.addLine(to: bottomRight)
        path.addLine(to: CGPoint(x: bottomRight.x, y: bottomRight.y - cornerLength))

        return path
    }
}
