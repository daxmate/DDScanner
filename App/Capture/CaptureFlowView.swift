// CaptureFlowView —— 生产拍摄流程（批 B1）：取景 → 拍摄 → 自动检测 → 几何矫正 → 屏内预览。
//
// 依赖全部来自组合根（`@Environment(\.scanEnvironment)`）：本文件**不 new 任何管线实现**，
// 只驱动 `CameraCaptureService`（采集）与 `PhotoScanRunner`（检测 + 几何矫正）。
//
// 线程纪律（同自测页 P0）：解码 + 检测 + 矫正一律 `Task.detached`，结果经 `@MainActor` 回填；
// 重拍 / 离页取消在途任务，取消后不回填过期结果。
// 失败路径一律「一行原因 + 「重拍」入口」，不留 UI 死路；相机中断 / 运行时错误由服务上报事件，
// 中断结束自动回到可拍。
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
        case failed(FailureReason)
    }

    /// 失败原因：既决定文案，也决定能否自动恢复。
    enum FailureReason: Equatable {
        /// 会话被系统中断（切后台 / 被占用 / 系统压力）；中断结束后自动回到可拍。
        case interrupted
        /// 会话运行时错误；服务已尝试自动重启，仍不可用则需点「重拍」。
        case runtimeError
        /// 拍摄时会话未在运行（未启动 / 已被停）。
        case notRunning
        /// 未能从照片中检测到文档边界。
        case documentNotFound
        /// 其它错误（细节已进 AppLog）。
        case other

        /// 屏幕上显示的一行原因。
        var message: String {
            switch self {
            case .interrupted: return String(localized: "capture.interrupted")
            case .runtimeError: return String(localized: "capture.runtimeError")
            case .notRunning: return String(localized: "capture.notRunning")
            case .documentNotFound: return String(localized: "capture.notFound")
            case .other: return String(localized: "capture.failed")
            }
        }
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
                // 断开与服务的长生命周期回调（服务持有本视图的闭包）。
                camera?.onEvent = nil
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
            failureBlock(reason)
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
            retakeButton

            Spacer(minLength: 0)
        }
        .padding()
    }

    /// 失败页：一行原因 + 「重拍」入口（与结果页同一按钮形态），不留死路。
    private func failureBlock(_ reason: FailureReason) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(reason.message)
                    .font(.body)
                    .multilineTextAlignment(.center)
            }
            retakeButton

            Spacer(minLength: 0)
        }
        .padding(24)
    }

    /// 结果页与失败页共用的「重拍」按钮形态。
    private var retakeButton: some View {
        Button {
            retake()
        } label: {
            Text(String(localized: "capture.retake"))
                .font(.title3)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
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

    /// 请求权限、挂上会话事件、启动预览。
    private func prepare() async {
        guard let camera else {
            fail(.other)
            return
        }
        camera.onEvent = { event in handleCameraEvent(event) }
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
            fail(.other)
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
                fail(Self.failureReason(for: error))
            }
        }
    }

    private func retake() {
        task?.cancel()
        correctedImage = nil
        phase = .ready
        camera?.startRunning()
    }

    /// 统一失败出口：落状态 + 停会话。
    ///
    /// 中断时**不**调 `stopRunning()`：会话已由系统停住，而 `stopRunning()` 会清掉服务的
    /// 「期望运行」意图，导致中断结束后无法自动恢复（自动恢复正是本路径要的）。
    private func fail(_ reason: FailureReason) {
        task?.cancel()
        phase = .failed(reason)
        if reason != .interrupted {
            camera?.stopRunning()
        }
    }

    /// 会话事件：中断给一行原因；中断结束自动回到可拍；运行时错误提示重拍。
    private func handleCameraEvent(_ event: CameraCaptureEvent) {
        switch event {
        case .interrupted:
            fail(.interrupted)
        case .resumed:
            if phase == .failed(.interrupted) { phase = .ready }
        case .runtimeError:
            fail(.runtimeError)
        }
    }

    /// 底层错误 → 失败原因（细节写日志，界面只给一行）。
    private static func failureReason(for error: any Error) -> FailureReason {
        if let cameraError = error as? CameraCaptureError, cameraError == .sessionNotRunning {
            return .notRunning
        }
        if let scannerError = error as? ScannerError, scannerError == .documentNotFound {
            return .documentNotFound
        }
        AppLog.error("拍摄流程失败：\(error)", category: .capture)
        return .other
    }
}
