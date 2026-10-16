// CaptureFlowView —— 生产拍摄流程（批 B1）：取景 → 拍摄 → 自动检测 → 几何矫正 → 屏内预览。
//
// 依赖全部来自组合根（`@Environment(\.scanEnvironment)`）：本文件**不 new 任何管线实现**，
// 只驱动 `CameraCaptureService`（采集）与 `PhotoScanRunner`（检测 + 几何矫正）。
//
// 线程纪律（同自测页 P0）：解码 + 检测 + 矫正一律 `Task.detached`，结果经 `@MainActor` 回填；
// 重拍 / 离页取消在途任务，取消后不回填过期结果。
// 权限被拒 / 设备无相机 / 检测不到文档 → 各给一行明确原因，不崩、不留白屏。
//
// 明确不做（后续批次）：四角拖拽微调（B2）、导出（B3）、UVDoc 弯页去畸变（v1 外）。
import CoreGraphics
import DDScannerCore
import SwiftUI

struct CaptureFlowView: View {
    @Environment(\.scanEnvironment) private var scanEnvironment

    /// 流程阶段。
    enum Phase: Equatable {
        case preparing
        case ready
        case capturing
        case processing
        case result
        case denied
        case unavailable
        case failed(String)
    }

    @State private var phase: Phase = .preparing
    @State private var correctedImage: CGImage?
    /// 在途任务（重拍 / 离页时取消）。
    @State private var task: Task<Void, Never>?

    private var camera: CameraCaptureService? { scanEnvironment?.camera }
    private var scanner: PhotoScanRunner? { scanEnvironment?.photoScanner }

    var body: some View {
        content
            .navigationTitle(String(localized: "capture.title"))
            .navigationBarTitleDisplayMode(.inline)
            .task { await prepare() }
            .onDisappear {
                task?.cancel()
                camera?.stopRunning()
            }
    }

    // MARK: - 视图

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .result:
            resultBlock
        case .denied:
            messageBlock(String(localized: "capture.denied"), symbol: "camera.metering.unknown")
        case .unavailable:
            messageBlock(String(localized: "capture.unavailable"), symbol: "camera.metering.unknown")
        case let .failed(reason):
            messageBlock(reason, symbol: "exclamationmark.triangle")
        default:
            cameraBlock
        }
    }

    private var cameraBlock: some View {
        VStack(spacing: 16) {
            ZStack {
                Color.black
                if let camera {
                    CameraPreviewView(session: camera.session)
                }
                if isBusy {
                    busyOverlay
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                capture()
            } label: {
                Text(String(localized: "capture.shutter"))
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(phase != .ready)

            Spacer(minLength: 0)
        }
        .padding()
    }

    private var resultBlock: some View {
        VStack(spacing: 16) {
            if let correctedImage {
                Image(decorative: correctedImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Button {
                retake()
            } label: {
                Text(String(localized: "capture.retake"))
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Spacer(minLength: 0)
        }
        .padding()
    }

    private var busyOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(busyText)
                .font(.footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func messageBlock(_ message: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isBusy: Bool {
        switch phase {
        case .preparing, .capturing, .processing: return true
        default: return false
        }
    }

    private var busyText: String {
        switch phase {
        case .preparing: return String(localized: "capture.preparing")
        case .capturing: return String(localized: "capture.capturing")
        default: return String(localized: "capture.processing")
        }
    }

    // MARK: - 流程

    /// 请求权限并启动预览。
    private func prepare() async {
        guard let camera else {
            phase = .failed(String(localized: "capture.failed"))
            return
        }
        switch await camera.prepare() {
        case .ready:
            camera.startRunning()
            if phase == .preparing { phase = .ready }
        case .denied:
            phase = .denied
        case .unavailable:
            phase = .unavailable
        }
    }

    /// 一次拍摄：拍照（全分辨率）→ 解码 → 自动检测 → 几何矫正 → 预览。
    private func capture() {
        guard let camera, let scanner else {
            phase = .failed(String(localized: "capture.failed"))
            return
        }
        task?.cancel()
        phase = .capturing
        task = Task { @MainActor in
            do {
                let data = try await camera.capturePhoto()
                try Task.checkCancellation()
                phase = .processing
                let result = try await Task.detached(priority: .userInitiated) {
                    let image = try CapturedPhotoDecoder.decode(data)
                    return try scanner.scan(image)
                }.value
                try Task.checkCancellation()
                camera.stopRunning()
                correctedImage = result.image
                phase = .result
            } catch is CancellationError {
                // 页面已离开或已重拍：不回填过期结果。
            } catch {
                phase = .failed(Self.message(for: error))
            }
        }
    }

    private func retake() {
        task?.cancel()
        correctedImage = nil
        phase = .ready
        camera?.startRunning()
    }

    /// 把底层错误收敛成一行可读原因（检测不到文档是最常见的一种）。
    private static func message(for error: any Error) -> String {
        if let scannerError = error as? ScannerError, scannerError == .documentNotFound {
            return String(localized: "capture.notFound")
        }
        AppLog.error("拍摄流程失败：\(error)", category: .capture)
        return String(localized: "capture.failed")
    }
}
