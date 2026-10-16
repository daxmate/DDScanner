// CameraCaptureService —— App 层**唯一**持有 AVFoundation 采集的位置（见 docs/architecture.md 批 B1）。
//
// 分层硬边界：相机采集是平台能力，只允许留在 App 层；Core 只允许 Foundation/CoreGraphics/Accelerate，
// Vision/Dewarp/Export 模块也不得 import AVFoundation（门禁见 scripts/check-forbidden-imports.sh）。
//
// 职责：请求相机权限 → 按需配置 `AVCaptureSession` → 供预览层取会话 → 交回一次全分辨率拍摄数据。
// 解码与几何都不在本文件：前者是 `CapturedPhotoDecoder`，后者是 `PhotoScanRunner`。
//
// 线程：会话配置 / startRunning / stopRunning / 委托表一律在专用串行队列上操作（AVFoundation 要求）；
// `capturePhoto()` 以 async 形式等待委托回调，调用方不得在主线程做重活。
import AVFoundation
import DDScannerCore
import Foundation

/// 相机可用性（`prepare()` 的结果）。
enum CameraAvailability: Equatable {
    case ready
    case denied
    case unavailable
}

/// 采集失败原因（App 层错误，不污染 Core 的 `ScannerError`）。
enum CameraCaptureError: Error, Equatable {
    case notPrepared
    case configurationFailed
    case unavailable
    case captureFailed(String)
}

/// 相机采集服务：一个实例对应一台设备的一个后置摄像头会话。
final class CameraCaptureService: NSObject, @unchecked Sendable {
    /// 预览层与采集共用的会话；`CameraPreviewView` 只读引用。
    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.daxmate.DDScanner.camera.session")
    /// 在途拍摄的委托（**仅** sessionQueue 上读写）：AVFoundation 要求委托对象存活到回调结束。
    private var pendingDelegates: [Int64: PhotoCaptureDelegate] = [:]
    /// 仅 sessionQueue 上读写。
    private var isConfigured = false
    private var isPrepared = false

    /// 请求权限并配置会话（幂等，不启动预览）。
    func prepare() async -> CameraAvailability {
        guard await Self.ensureAuthorized() else {
            AppLog.warning("相机权限未授予，采集不可用", category: .capture)
            return .denied
        }
        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                do {
                    try self.configureIfNeeded()
                    self.isPrepared = true
                    continuation.resume(returning: .ready)
                } catch {
                    AppLog.error("相机会话配置失败：\(error)", category: .capture)
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    /// 启动预览（`prepare()` 返回 `.ready` 后调用；重复调用无副作用）。
    func startRunning() {
        sessionQueue.async {
            guard self.isPrepared, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    /// 停止预览（离页时调用；重复调用无副作用）。
    func stopRunning() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// 拍摄一张**全分辨率**照片，返回原始编码数据（方向由 `CapturedPhotoDecoder` 按 EXIF 摆正）。
    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                guard self.isPrepared else {
                    continuation.resume(throwing: CameraCaptureError.notPrepared)
                    return
                }
                self.pruneFinishedDelegates()
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .quality
                let delegate = PhotoCaptureDelegate(continuation: continuation)
                self.pendingDelegates[settings.uniqueID] = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    // MARK: - 内部

    /// 清掉已结束的委托；在途的一律保留（AVFoundation 要求委托活到回调结束）。
    private func pruneFinishedDelegates() {
        pendingDelegates = pendingDelegates.filter { !$0.value.isFinished }
    }

    private static func ensureAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video) else {
            throw CameraCaptureError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input) else { throw CameraCaptureError.configurationFailed }
        session.addInput(input)
        guard session.canAddOutput(photoOutput) else { throw CameraCaptureError.configurationFailed }
        session.addOutput(photoOutput)
        isConfigured = true
        AppLog.info("相机会话就绪（后置广角，photo 预设）", category: .capture)
    }

    deinit {
        if session.isRunning { session.stopRunning() }
    }
}

/// 单次拍摄的委托桥：把 AVFoundation 的多段回调收敛成**一次性** continuation。
///
/// 不反向持有服务（避免循环持有与 weak 捕获的告警）：服务按下一次拍摄时按 `isFinished` 清理。
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let continuation: CheckedContinuation<Data, Error>
    private let lock = NSLock()
    private var didResume = false
    private var finished = false

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    /// 本次拍摄是否已走完 `didFinishCaptureFor`（持有方据此清理）。
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        resumeOnce {
            if let error { return .failure(error) }
            guard let data = photo.fileDataRepresentation(), !data.isEmpty else {
                return .failure(CameraCaptureError.captureFailed("拍摄未返回像素数据"))
            }
            return .success(data)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Error)?
    ) {
        // 兜底：处理阶段未回调（或回调失败）时也必须把 continuation 收掉，否则调用方永久挂起。
        resumeOnce { .failure(error ?? CameraCaptureError.captureFailed("拍摄未完成")) }
        lock.lock()
        finished = true
        lock.unlock()
    }

    /// 只回填一次。
    private func resumeOnce(_ outcome: () -> Result<Data, any Error>) {
        lock.lock()
        let shouldResume = !didResume
        didResume = true
        lock.unlock()
        guard shouldResume else { return }
        continuation.resume(with: outcome())
    }
}
