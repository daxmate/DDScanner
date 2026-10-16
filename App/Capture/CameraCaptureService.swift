// CameraCaptureService —— App 层**唯一**持有 AVFoundation 采集的位置（见 docs/architecture.md 批 B1）。
//
// 分层硬边界：相机采集是平台能力，只允许留在 App 层；Core 只允许 Foundation/CoreGraphics/Accelerate，
// Vision/Dewarp/Export 模块也不得 import AVFoundation（门禁见 scripts/check-forbidden-imports.sh）。
//
// 职责：请求相机权限 → 按需配置 `AVCaptureSession` → 供预览层取会话 → 交回一次全分辨率拍摄数据 →
// 观察系统中断 / 运行时错误并**自动恢复**。解码与几何都不在本文件：前者是 `CapturedPhotoDecoder`，
// 后者是 `PhotoScanRunner`。
//
// 线程：会话配置 / startRunning / stopRunning / 委托表一律在专用串行队列上操作（AVFoundation 要求）；
// `capturePhoto()` 以 async 形式等待委托回调，调用方不得在主线程做重活；
// `onEvent` 一律在**主线程**投递（服务内部做 hop）。
import AVFoundation
import DDScannerCore
import Foundation

/// 相机可用性（`prepare()` 的结果）。
enum CameraAvailability: Equatable {
    case ready
    case denied
    case unavailable
}

/// 会话级事件（供界面给出「一行原因 + 恢复动作」）。
enum CameraCaptureEvent: Equatable {
    /// 会话被系统中断（切后台 / 被其它 App 占用 / 系统压力）。中断结束后会自动恢复。
    case interrupted
    /// 中断结束，会话已自动恢复。
    case resumed
    /// 会话运行时错误（会话已停止；服务会尝试自动重启）。
    case runtimeError
}

/// 采集失败原因（App 层错误，不污染 Core 的 `ScannerError`）。
enum CameraCaptureError: Error, Equatable {
    case notPrepared
    case configurationFailed
    case unavailable
    /// 拍摄时会话未处于运行态（未启动 / 已被停 / 正被系统中断）。
    case sessionNotRunning
    case captureFailed(String)
}

/// 相机采集服务：一个实例对应一台设备的一个后置摄像头会话。
final class CameraCaptureService: NSObject, @unchecked Sendable {
    /// 预览层与采集共用的会话；`CameraPreviewView` 只读引用。
    let session = AVCaptureSession()

    /// 会话级事件回调（**主线程**投递）。由界面层设置；界面消失时应置 `nil` 断开与界面的引用。
    var onEvent: ((CameraCaptureEvent) -> Void)?

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.daxmate.DDScanner.camera.session")
    /// 在途拍摄的委托（**仅** sessionQueue 上读写）：AVFoundation 要求委托对象存活到回调结束。
    private var pendingDelegates: [Int64: PhotoCaptureDelegate] = [:]
    /// 通知观察者；`deinit` 里注销（注册用 `[weak self]`，不会被通知中心反向持有）。
    private var observers: [NSObjectProtocol] = []
    /// 仅 sessionQueue 上读写。
    private var isConfigured = false
    private var isPrepared = false
    /// 是否**期望**会话处于运行态（中断 / 运行时错误后的自动恢复据此决定要不要重启）；仅 sessionQueue 上读写。
    private var wantsRunning = false

    override init() {
        super.init()
        registerSessionObservers()
    }

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
            self.wantsRunning = true
            self.startIfNeeded()
        }
    }

    /// 停止预览（离页 / 失败态调用；重复调用无副作用）。会清掉「期望运行」意图，不再自动恢复。
    func stopRunning() {
        sessionQueue.async {
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
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
                // 中断 / 已停 / 运行时错误之后不要盲拍：先校验会话真的在跑。
                guard self.session.isRunning else {
                    continuation.resume(throwing: CameraCaptureError.sessionNotRunning)
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

    /// 启动（幂等）：仅当「已配置 + 期望运行 + 当前未运行」时才调用 `startRunning()`。
    private func startIfNeeded() {
        guard isPrepared, wantsRunning, !session.isRunning else { return }
        session.startRunning()
    }

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

    // MARK: - 中断 / 运行时错误

    /// 观察系统中断与会话错误。注册用 `[weak self]`：通知中心持有的是 block，不能反向把它留住。
    private func registerSessionObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let reason = Self.interruptionReasonText(notification)
            AppLog.warning("相机会话被中断（\(reason)），中断结束后自动恢复", category: .capture)
            self?.notifyOnMain(.interrupted)
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            AppLog.info("相机会话中断结束，尝试恢复预览", category: .capture)
            self.scheduleStartIfNeeded()
            self.notifyOnMain(.resumed)
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?
                .localizedDescription ?? "未知错误"
            AppLog.error("相机会话运行时错误：\(detail)", category: .capture)
            self.scheduleStartIfNeeded()
            self.notifyOnMain(.runtimeError)
        })
    }

    /// 在会话队列上尝试恢复（Apple 允许在中断结束 / 运行时错误后重启会话）。
    private func scheduleStartIfNeeded() {
        sessionQueue.async {
            self.startIfNeeded()
        }
    }

    /// 事件一律在主线程投递；界面只做状态搬运，重活不在这里。
    private func notifyOnMain(_ event: CameraCaptureEvent) {
        DispatchQueue.main.async {
            self.onEvent?(event)
        }
    }

    /// 中断原因码 → 人话（仅进日志；界面用的是本地化的一行原因）。
    private static func interruptionReasonText(_ notification: Notification) -> String {
        guard let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return "未知原因"
        }
        // 用相等判断而非 switch：该枚举由 Objective-C 导入，`@unknown default` 不接受、
        // 写全 case 又会触发「switch must be exhaustive」（新增原因码时还会变红）。
        if reason == .videoDeviceNotAvailableInBackground { return "进入后台" }
        if reason == .audioDeviceInUseByAnotherClient { return "音频设备被其它客户端占用" }
        if reason == .videoDeviceInUseByAnotherClient { return "视频设备被其它客户端占用" }
        if reason == .videoDeviceNotAvailableWithMultipleForegroundApps { return "多窗口前台" }
        if reason == .videoDeviceNotAvailableDueToSystemPressure { return "系统压力" }
        return "原因码 \(raw)"
    }

    deinit {
        // 注册用的是 weak self，这里显式注销（服务随 App 生命周期，退出时才走到）。
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        // 刻意**不**在 deinit 里 stopRunning()：本对象销毁时 session 一并释放，AVFoundation 自行收尾；
        // 而此刻 sessionQueue 可能已不可用，异步 stop 没有意义（复核意见 P2-2）。
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
