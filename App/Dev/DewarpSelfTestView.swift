// 开发用「去畸变自测页」——真机看数字与**分阶段**效果（仅 DEBUG；步骤见 docs/device-test-uvdoc.md）。
//
// ⚠️ 线程纪律（P0，2026-09-30）：整条管线**不在主线程**跑（`Task.detached(priority: .userInitiated)`），
// 结果经 `@MainActor` 回填；每次新任务先 `cancel()` 上一个（重跑 / 换图 / 离开页面），取消后不回填过期结果。
// 界面按阶段显示进度（载入 → 检测 → 矫正 → 预处理 → 推理 n/N → 重采样），不再无声占住。
//
// 管线（批 8 接上）：原图 → Vision 文档检测 → 透视矫正 + 裁切（全分辨率）→ UVDoc 去畸变。
// 只读 Environment（依赖由组合根装配）：模型不可用时**优雅降级**为一行原因，不崩、不留白屏。
#if DEBUG
    import CoreGraphics
    import DDScannerCore
    import DDScannerDewarp
    import PhotosUI
    import SwiftUI

    struct DewarpSelfTestView: View {
        /// 图像来源。
        private enum LoadSource {
            case sample
            case loaded(DevPhotoLoadResult)
            case picked(PhotosPickerItem)

            var isPicked: Bool {
                if case .sample = self { return false }
                return true
            }
        }

        @Environment(\.scanEnvironment) private var scanEnvironment
        @State private var report: DewarpSelfTestReport?
        @State private var failure: String?
        @State private var isRunning = false
        @State private var stage: DewarpSelfTestStage = .idle
        /// 当前在跑的后台任务（重跑 / 换图 / 离页时取消）。
        @State private var task: Task<Void, Never>?
        /// 已读入的相册照片（nil = 用内置样例）。
        @State private var pickedPhoto: DevPhotoLoadResult?
        @State private var pickerItem: PhotosPickerItem?
        /// 检测框叠加图（在主线程画好后存起来，避免每次刷新重绘）。
        @State private var overlayImage: UIImage?
        /// 纸张增强选择（去折痕 / 提白 / 换纸色）——改档后按「重跑」重算全分辨率结果。
        @State private var enhanceWhiteness: PaperWhitenessChoice = .conservative
        @State private var enhanceColor: PaperColorPreset = .white
        /// 点按某张图后进入全屏查看（nil = 未打开）。
        @State private var previewItem: ImagePreviewItem?

        /// 推理次数（自测页固定 30 次，取 min/median/max）。
        private let iterations = 30
        /// 分阶段图的显示高度（让两行对齐）。
        private let stageHeight: CGFloat = 170

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusBlock
                    if let report, !isRunning {
                        metricsBlock(report)
                        stageBlock(report)
                        paperBlock(report)
                    } else if let failure, !isRunning {
                        failureBlock(failure)
                    } else {
                        runningBlock
                    }
                    footnote
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("去畸变自测")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $previewItem) { FullScreenImageViewer(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Text("选照片")
                    }
                    .disabled(isRunning)
                    .accessibilityLabel("从相册选一张照片自测")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重跑") { run() }
                        .disabled(isRunning)
                }
            }
            .task {
                if report == nil, failure == nil, !isRunning { run() }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                start(source: .picked(item))
            }
            .onDisappear {
                task?.cancel()
            }
        }

        // MARK: 各区块

        private var statusBlock: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("模型状态").font(.headline)
                Text(scanEnvironment?.dewarpStatus ?? "Environment 未注入")
                    .font(.footnote)
                    .foregroundStyle(scanEnvironment?.gridPredictor == nil ? .red : .secondary)
            }
        }

        private func metricsBlock(_ report: DewarpSelfTestReport) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("实测数字").font(.headline)
                row("设备 / 系统", report.device)
                row("算力（MLComputeUnits）", report.computeUnits)
                row("图像来源", report.sourceLabel)
                row("源图尺寸", report.sourceSize)
                row("载入后尺寸", report.loadedSize)
                row("载入耗时", milliseconds(report.loadMilliseconds))
                detectionRow(report)
                row("裁切结果", report.rectifiedSize)
                row("输入尺寸", report.inputSize)
                row("输出网格", report.gridSize)
                row("推理次数", "\(report.iterations)")
                row("推理 min / median / max", String(
                    format: "%.2f / %.2f / %.2f ms",
                    report.inferenceMinimumMilliseconds,
                    report.inferenceMedianMilliseconds,
                    report.inferenceMaximumMilliseconds
                ))
                row("单次均耗时（含首跑）", milliseconds(report.inferenceTotalMilliseconds / Double(report.iterations)))
            }
            .font(.footnote)
        }

        /// 检测状态单列一行：未检测到（已回退）用橙色标出来。
        private func detectionRow(_ report: DewarpSelfTestReport) -> some View {
            HStack(alignment: .firstTextBaseline) {
                Text("检测状态").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text("\(report.detectionStatus) · \(milliseconds(report.detectionMilliseconds))")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(report.detectionStatus.hasPrefix("已检测到") ? Color.secondary : Color.orange)
            }
        }

        private func stageBlock(_ report: DewarpSelfTestReport) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("分阶段对比").font(.headline)
                Text("点按任意图片可全屏放大查看细节")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    stageCell(
                        "①", "原图", image: UIImage(cgImage: report.originalImage),
                        detail: "载入 \(milliseconds(report.loadMilliseconds))"
                    )
                    stageCell(
                        "②", "检测框叠加", image: overlayImage ?? UIImage(cgImage: report.originalImage),
                        detail: "检测 \(milliseconds(report.detectionMilliseconds))"
                    )
                }
                HStack(alignment: .top, spacing: 8) {
                    stageCell(
                        "③", "裁切 + 透视矫正", image: UIImage(cgImage: report.rectifiedImage),
                        detail: "矫正 \(milliseconds(report.rectificationMilliseconds))"
                    )
                    stageCell(
                        "④", "去畸变后", image: UIImage(cgImage: report.dewarpedImage),
                        detail: "预处理 \(milliseconds(report.preprocessMilliseconds)) + 重采样 \(milliseconds(report.resampleMilliseconds))"
                    )
                }
            }
        }

        private func stageCell(_ index: String, _ title: String, image: UIImage, detail: String) -> some View {
            let name = "\(index) \(title)"
            let pixels = Self.pixelSize(of: image)
            return VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.caption).bold()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: stageHeight)
                    .border(Color.secondary.opacity(0.4))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        previewItem = ImagePreviewItem(image: image, title: name, detail: "\(pixels) · \(detail)")
                    }
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// 图像的真实像素尺寸（`UIImage(cgImage:)` 未二次降采样，尺寸即像素）。
        private static func pixelSize(of image: UIImage) -> String {
            let size = image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? image.size
            return "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
        }

        /// 纸张增强块：档位切换 + 全分辨率结果 + 各档并列预览。
        private func paperBlock(_ report: DewarpSelfTestReport) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("纸张增强（去折痕 / 提白 / 换纸色）").font(.headline)
                Picker("白度", selection: $enhanceWhiteness) {
                    ForEach(PaperWhitenessChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                Picker("纸色", selection: $enhanceColor) {
                    ForEach(PaperColorPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                Text("当前档：\(report.paperEnhanceTitle) · 全分辨率耗时 \(milliseconds(report.paperEnhanceMilliseconds))（改档位后按「重跑」重算）")
                    .font(.caption2).foregroundStyle(.secondary)
                Image(uiImage: UIImage(cgImage: report.paperEnhancedImage))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: stageHeight)
                    .border(Color.secondary.opacity(0.4))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        previewItem = ImagePreviewItem(
                            image: UIImage(cgImage: report.paperEnhancedImage),
                            title: "⑤ 纸张增强（全分辨率）",
                            detail: "\(Self.pixelSize(of: UIImage(cgImage: report.paperEnhancedImage)))"
                                + " · 当前档 \(report.paperEnhanceTitle)"
                                + " · \(milliseconds(report.paperEnhanceMilliseconds))"
                        )
                    }
                Text("各档并列（关闭 / 255 / 310 × 白 / 米白 / 暖黄）").font(.caption).bold()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(report.paperEnhancePreviews) { preview in
                        previewCell(preview)
                    }
                }
            }
        }

        /// 网格里的一档预览（可点开全屏）。
        private func previewCell(_ preview: PaperEnhancePreview) -> some View {
            let image = UIImage(cgImage: preview.image)
            return VStack(spacing: 2) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .border(Color.secondary.opacity(0.3))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        previewItem = ImagePreviewItem(
                            image: image,
                            title: "⑤ 预览 · \(preview.title)",
                            detail: Self.pixelSize(of: image)
                        )
                    }
                Text(preview.title).font(.caption2).foregroundStyle(.secondary)
            }
        }

        private func failureBlock(_ message: String) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("未能完成自测").font(.headline).foregroundStyle(.red)
                Text(message).font(.footnote)
            }
        }

        private var runningBlock: some View {
            HStack(spacing: 8) {
                ProgressView()
                Text(stage.text).font(.footnote)
            }
        }

        private var footnote: some View {
            Text("仅 DEBUG 构建包含本页。管线在后台线程执行，界面不再被占住；Mac 上的 2.28 ms 只是指示值。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        private func row(_ title: String, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).multilineTextAlignment(.trailing)
            }
        }

        private func milliseconds(_ value: Double) -> String {
            String(format: "%.2f ms", value)
        }

        // MARK: 执行

        /// 跑当前来源：已选照片优先，否则内置样例（进页面自动跑的就是这条）。
        private func run() {
            if let pickedPhoto {
                start(source: .loaded(pickedPhoto))
            } else {
                start(source: .sample)
            }
        }

        /// 启动一次自测：先取消上一个任务，再把整条管线放到后台线程。
        private func start(source: LoadSource) {
            task?.cancel()
            guard let environment = scanEnvironment else {
                report = nil
                failure = "Environment 未注入（组合根未装配）"
                return
            }
            guard let predictor = environment.gridPredictor else {
                // 优雅降级：模型不可用只显示原因，页面照常可用。
                report = nil
                failure = environment.dewarpStatus
                return
            }
            isRunning = true
            failure = nil
            report = nil
            overlayImage = nil
            stage = .loading

            // 只抓 Sendable 的片段进后台，避免把整个 Environment 带过去。
            let detector = environment.imageDetector
            let corrector = environment.perspectiveCorrector
            let modelStatus = environment.dewarpStatus
            let computeUnits = environment.dewarpComputeUnits
            let device = DeviceDescription.current
            let iterations = iterations
            let isPicked = source.isPicked
            let paperSelection = PaperEnhanceSelection(whiteness: enhanceWhiteness, color: enhanceColor)

            task = Task.detached(priority: .userInitiated) {
                let photo: DevPhotoLoadResult
                do {
                    switch source {
                    case .sample:
                        photo = try DewarpSelfTestRunner.loadSamplePhoto()
                    case let .loaded(existing):
                        photo = existing
                    case let .picked(item):
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw DewarpSelfTestError.photoDataMissing
                        }
                        photo = try DevPhotoLoader.load(data: data)
                    }
                    try Task.checkCancellation()
                } catch {
                    let message = isPicked ? "读取所选照片失败：\(error)" : "\(error)"
                    await MainActor.run {
                        self.overlayImage = nil
                        self.report = nil
                        self.failure = message
                        self.isRunning = false
                    }
                    return
                }

                do {
                    let runnerReport = try DewarpSelfTestRunner.run(
                        photo: photo,
                        sourceLabel: isPicked ? "相册照片" : "内置样例 \(DewarpSelfTestRunner.sampleResource)",
                        detector: detector,
                        corrector: corrector,
                        predictor: predictor,
                        descriptor: .uvDoc,
                        modelStatus: modelStatus,
                        computeUnits: computeUnits,
                        device: device,
                        iterations: iterations,
                        paperSelection: paperSelection,
                        progress: { stage in
                            Task { @MainActor in self.stage = stage }
                        }
                    )
                    if Task.isCancelled { return }
                    await MainActor.run {
                        if isPicked { self.pickedPhoto = photo }
                        self.overlayImage = Self.overlayImage(from: photo.image, quad: runnerReport.detectionQuad)
                        self.report = runnerReport
                        self.stage = .finished
                        self.isRunning = false
                    }
                } catch is CancellationError {
                    await MainActor.run { self.isRunning = false }
                } catch {
                    await MainActor.run {
                        self.overlayImage = nil
                        self.report = nil
                        self.failure = "\(error)"
                        self.isRunning = false
                    }
                }
            }
        }

        /// 在原图上叠加检测框（缩放显示，`quad` 为归一化坐标）；`nil` 时返回原图。**主线程**执行。
        @MainActor
        private static func overlayImage(from image: CGImage, quad: DocumentQuad?) -> UIImage {
            let pixelSize = CGSize(width: image.width, height: image.height)
            let maximumDimension: CGFloat = 1400
            let longest = max(pixelSize.width, pixelSize.height)
            let factor = longest > maximumDimension ? maximumDimension / longest : 1
            let target = CGSize(
                width: max(1, (pixelSize.width * factor).rounded()),
                height: max(1, (pixelSize.height * factor).rounded())
            )
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: target, format: format).image { _ in
                UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: target))
                guard let quad else { return }
                let points = quad.points.map { CGPoint(x: $0.x * target.width, y: $0.y * target.height) }
                let path = UIBezierPath()
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                path.close()
                UIColor.systemGreen.setStroke()
                path.lineWidth = max(2, target.width * 0.005)
                path.stroke()
            }
        }
    }

    @MainActor
    enum DeviceDescription {
        /// 机型标识 + 系统版本（自测页要把这两项显示出来，便于回截图）。
        static var current: String {
            "\(UIDevice.current.model) \(machineIdentifier) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        }

        private static var machineIdentifier: String {
            var info = utsname()
            uname(&info)
            return withUnsafeBytes(of: &info.machine) { raw in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "unknown" }
                return String(cString: base)
            }
        }
    }
#endif
