// CameraCaptureService —— App 层**唯一**持有 AVFoundation 采集的位置（见 docs/architecture.md 批 B1）。
//
// 分层硬边界：相机采集是平台能力，只允许留在 App 层；Core 只允许 Foundation/CoreGraphics/Accelerate，
// Vision/Dewarp/Export 模块也不得 import AVFoundation（门禁见 scripts/check-forbidden-imports.sh）。
//
// 职责：请求相机权限 → 按需配置 `AVCaptureSession` → 供预览层取会话 → 交回一次全分辨率拍摄数据 →
// 观察系统中断 / 运行时错误并**带退避与上限地自动恢复**。解码与几何都不在本文件：前者是
// `CapturedPhotoDecoder`，后者是 `PhotoScanRunner`。
//
// 线程：会话配置 / startRunning / stopRunning / 委托表 / 恢复状态一律在专用串行队列上操作
// （AVFoundation 要求）；`capturePhoto()` 以 async 形式等待委托回调，调用方不得在主线程做重活；
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

/// 会话级事件（供界面给出「一行原因 / 不打断的提示 + 恢复动作」）。
enum CameraCaptureEvent: Equatable {
    /// 会话被系统中断（切后台 / 被其它 App 占用 / 系统压力）。中断结束后会自动恢复。
    case interrupted
    /// 中断结束，且会话**已确认恢复运行**——界面可回到可拍。
    case resumed
    /// 运行时错误发生，已开始按退避自动重启；界面只给不打断的提示，**不要**进失败态。
    case recoveryStarted
    /// 自动恢复成功，会话已确认在运行；界面留在原态。
    case recoverySucceeded
    /// 自动恢复失败或已达重试上限；只有到这一步才需要界面进失败态并给「重拍」。
    case recoveryFailed
}

/// 采集失败原因（App 层错误，不污染 Core 的 `ScannerError`）。
enum CameraCaptureError: Error, Equatable {
    case notPrepared
    case configurationFailed
    case unavailable
    /// 拍摄时会话未处于运行态（未启动 / 已被停 / 正被系统中断）。
    case sessionNotRunning
    /// 拍照输出没有可用的视频连接（通常是会话配置异常或设备被占用）。
    case noVideoConnection
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
    /// 通知观察者；`deinit` 里注销（注册用 `[weak self]`，不会被通知中心反向持有）。
    private var observers: [NSObjectProtocol] = []
    /// 事件回调表（跨线程读写，用锁保护）。
    private let eventLock = NSLock()
    private var eventHandler: ((CameraCaptureEvent) -> Void)?
    /// 仅 sessionQueue 上读写。
    private var isConfigured = false
    private var isPrepared = false
    /// 是否**期望**会话处于运行态（自动恢复据此决定要不要重启）；仅 sessionQueue 上读写。
    private var wantsRunning = false
    /// 同一错误连续自动重启的次数（超过上限即放弃）；仅 sessionQueue 上读写。
    private var recoveryAttempts = 0
    /// 恢复代次：关闭 / 用户重启 / 新一轮恢复都会 +1，用来作废过期的延迟任务；仅 sessionQueue 上读写。
    private var recoveryGeneration = 0

    /// 会话级事件回调（**主线程**投递）。由界面层设置；界面消失时应置 `nil`（服务随之不再自愈）。
    var onEvent: ((CameraCaptureEvent) -> Void)? {
        get {
            eventLock.lock()
            defer { eventLock.unlock() }
            return eventHandler
        }
        set {
            eventLock.lock()
            eventHandler = newValue
            eventLock.unlock()
        }
    }

    /// 自动恢复参数。
    private static let maxAutoRecoveryAttempts = 3
    /// 每次重启前的退避（秒）；下标 = 已连续失败的次数（超出取最后一个）。
    private static let autoRecoveryBackoff: [Double] = [0.5, 2.0, 5.0]
    /// 重启后静置多久没有新错误，才算恢复成功（秒）。
    private static let autoRecoverySettle: Double = 1.0

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
    /// 这是**用户显式意图**：会清零自动恢复的退避计数，重新武装自愈。
    func startRunning() {
        sessionQueue.async {
            self.wantsRunning = true
            self.recoveryAttempts = 0
            self.recoveryGeneration += 1
            self.startIfNeeded()
        }
    }

    /// 停止预览（离页 / 失败态调用；重复调用无副作用）。会清掉「期望运行」意图，待发的恢复任务随之作废。
    func stopRunning() {
        sessionQueue.async {
            self.wantsRunning = false
            self.recoveryGeneration += 1
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
                // 中断 / 已停 / 恢复窗口里都不要盲拍：先校验会话真的在跑。
                guard self.session.isRunning else {
                    continuation.resume(throwing: CameraCaptureError.sessionNotRunning)
                    return
                }
                guard let connection = self.photoOutput.connection(with: .video), connection.isEnabled else {
                    continuation.resume(throwing: CameraCaptureError.noVideoConnection)
                    return
                }
                self.pruneFinishedDelegates()
                let settings = AVCapturePhotoSettings()
                // 请求值必须收敛到本输出声明的上限：默认上限是 .balanced，直接请求 .quality
                // 会被 AVFoundation 以 NSInvalidArgumentException 拒绝（无法捕获 → 真机闪崩）。
                let maxQuality = self.photoOutput.maxPhotoQualityPrioritization
                settings.photoQualityPrioritization = maxQuality.rawValue
                    >= AVCapturePhotoOutput.QualityPrioritization.quality.rawValue ? .quality : maxQuality
                AppLog.info(
                    "开始拍照：maxQuality=\(maxQuality.rawValue) 请求=\(settings.photoQualityPrioritization.rawValue) "
                        + "连接启用=\(connection.isEnabled) 输出格式=\(self.photoOutput.availablePhotoCodecTypes.count)",
                    category: .capture
                )
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
        // 显式抬高本输出的质量上限（默认 .balanced）：拍摄时请求 .quality 超过上限会被
        // AVFoundation 抛 NSInvalidArgumentException —— 该异常无法在 Swift 侧捕获，直接闪崩。
        photoOutput.maxPhotoQualityPrioritization = .quality
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
            self.recoverAfterInterruption()
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
            self.beginRuntimeRecovery()
        })
    }

    /// 中断结束：重启会话，并**确认真的在跑**之后才通知界面可拍（避免恢复窗口里点快门撞
    /// `sessionNotRunning`）；起不来则交给界面重拍。
    private func recoverAfterInterruption() {
        sessionQueue.async {
            self.recoveryAttempts = 0
            self.recoveryGeneration += 1
            self.startIfNeeded()
            if self.session.isRunning {
                self.notifyOnMain(.resumed)
            } else {
                AppLog.error("中断结束后会话未能恢复运行", category: .capture)
                self.notifyOnMain(.recoveryFailed)
            }
        }
    }

    /// 运行时错误入口：没有事件消费者（界面未挂载）就**不自愈**，只记日志。
    private func beginRuntimeRecovery() {
        guard hasConsumer else {
            AppLog.error("界面未挂载（无事件消费者），跳过自动重启", category: .capture)
            return
        }
        notifyOnMain(.recoveryStarted)
        sessionQueue.async {
            self.scheduleRuntimeRecovery()
        }
    }

    /// 按退避重启会话；连续失败达上限即放弃（保留失败态，由界面给「重拍」）。
    private func scheduleRuntimeRecovery() {
        guard hasConsumer else {
            AppLog.error("恢复途中界面卸载，停止自动重启", category: .capture)
            return
        }
        guard recoveryAttempts < Self.maxAutoRecoveryAttempts else {
            AppLog.error("自动恢复连续失败 \(recoveryAttempts) 次，放弃（交由界面重拍）", category: .capture)
            notifyOnMain(.recoveryFailed)
            return
        }
        let index = min(recoveryAttempts, Self.autoRecoveryBackoff.count - 1)
        let delay = Self.autoRecoveryBackoff[index]
        recoveryAttempts += 1
        recoveryGeneration += 1
        let generation = recoveryGeneration
        AppLog.warning("自动恢复第 \(recoveryAttempts)/\(Self.maxAutoRecoveryAttempts) 次（\(delay)s 后）", category: .capture)
        sessionQueue.asyncAfter(deadline: .now() + delay) {
            self.startIfNeeded()
            guard self.session.isRunning else {
                self.scheduleRuntimeRecovery()
                return
            }
            // 静置窗口内不再报错（代次未变）→ 视为恢复成功，清零计数。
            self.sessionQueue.asyncAfter(deadline: .now() + Self.autoRecoverySettle) {
                guard self.recoveryGeneration == generation else { return }
                self.recoveryAttempts = 0
                self.notifyOnMain(.recoverySucceeded)
            }
        }
    }

    /// 是否有事件消费者（界面挂载）——没有就不自愈。
    private var hasConsumer: Bool { onEvent != nil }

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
        // 用相等判断而非 switch：该枚举由 Objective-C 导入，`@unknown default` 不被接受，
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
