// 开发用去畸变自测：跑「检测 → 透视矫正 → 去畸变」全前段、分阶段计时、出对比图（仅 DEBUG）。
//
// ⚠️ 线程纪律（P0，2026-09-30）：本类型的 `run(...)` **不在主线程**执行（不加 `@MainActor`），
// 视图侧用 `Task.detached` 调用、经 `@MainActor` 回填结果。真机血例：整条管线（30 次推理 +
// 全分辨率重采样）跑在主线程 → 界面冻死数秒～十几秒，退出重开仍卡死。
//   - 只依赖 Core 的纯逻辑 + Core ML；输入输出一律 `CGImage` / `FloatImage`，**不在后台造 UIImage**。
//   - 每阶段前 `Task.checkCancellation()`；推理循环走 `StagedLoop`（逐轮回报进度 + 可取消）。
//   - 大图守卫：源平面像素数必须 ≤ `GridResampler.maximumSourcePixelCount`（2^24），否则明确报错。
//
// 降级：**检测不到文档**时回退到「整帧直接去畸变」，页面写明「未检测到文档（已回退）」，不崩、不留白。
#if DEBUG
    import CoreGraphics
    import CoreML
    import DDScannerCore
    import DDScannerDewarp
    import DDScannerVision
    import Foundation

    /// 自测阶段（进度可见性：界面据此逐阶段刷新，不再无声占住）。
    enum DewarpSelfTestStage: Equatable, Sendable {
        case idle
        case loading
        case detecting
        case rectifying
        case preprocessing
        case inference(completed: Int, total: Int)
        case resampling
        case enhancing
        case finished

        /// 一行进度文案。
        var text: String {
            switch self {
            case .idle: return "准备中"
            case .loading: return "载入图片"
            case .detecting: return "检测文档边界"
            case .rectifying: return "透视矫正 + 裁切"
            case .preprocessing: return "预处理（缩放到输入）"
            case let .inference(completed, total): return "推理 \(completed)/\(total)"
            case .resampling: return "全分辨率重采样"
            case .enhancing: return "纸张增强（去折痕 / 提白 / 换纸色）"
            case .finished: return "完成"
            }
        }
    }

    /// 白度档（自测页可切换）。`nil` = 关闭（原图）。
    enum PaperWhitenessChoice: String, CaseIterable, Identifiable {
        case off
        case conservative
        case maximum

        var id: String { rawValue }

        /// 一行展示名。
        var title: String {
            switch self {
            case .off: return "关闭"
            case .conservative: return "白度 255"
            case .maximum: return "白度 310"
            }
        }

        /// 白度值；`nil` = 关闭。
        var whiteness: Double? {
            switch self {
            case .off: return nil
            case .conservative: return PaperEnhanceOptions.defaultWhiteness
            case .maximum: return PaperEnhanceOptions.maximumWhiteness
            }
        }
    }

    /// 自测页当前选择的增强档（白度 × 纸色）。
    struct PaperEnhanceSelection: Equatable {
        var whiteness: PaperWhitenessChoice = .conservative
        var color: PaperColorPreset = .white

        /// 对应的 Core 选项；关闭时为 `nil`（逐字节 no-op）。
        var options: PaperEnhanceOptions? {
            guard let value = whiteness.whiteness else { return nil }
            return PaperEnhanceOptions(whiteness: value, paperColor: color.paperColor)
        }

        var title: String { "\(whiteness.title) · \(color.displayName)" }
    }

    /// 一档增强预览（并列对比用，已降采样到显示尺寸）。
    struct PaperEnhancePreview: Identifiable {
        let title: String
        let image: CGImage
        var id: String { title }
    }

    /// 一次自测的完整结果（视图只负责展示；图像一律 `CGImage`，`UIImage` 由视图在主线程包）。
    struct DewarpSelfTestReport {
        var modelStatus: String
        var computeUnits: String
        var device: String
        /// 图像来源（内置样例 / 相册照片）。
        var sourceLabel: String
        /// 源图像素尺寸（应用 EXIF 方向后）。
        var sourceSize: String
        /// 实际读入尺寸（超上限时含「已降采样」说明）。
        var loadedSize: String
        /// 读入耗时（毫秒）。
        var loadMilliseconds: Double
        /// 检测状态（命中置信度 / 未检测到已回退）。
        var detectionStatus: String
        /// 检测耗时（毫秒）。
        var detectionMilliseconds: Double
        /// 裁切 + 透视矫正耗时（毫秒，含 Core 重采样）。
        var rectificationMilliseconds: Double
        /// 裁切结果尺寸（或「未裁切」说明）。
        var rectifiedSize: String
        var iterations: Int
        var inputSize: String
        var gridSize: String
        var preprocessMilliseconds: Double
        var inferenceMinimumMilliseconds: Double
        var inferenceMedianMilliseconds: Double
        var inferenceMaximumMilliseconds: Double
        var inferenceTotalMilliseconds: Double
        var resampleMilliseconds: Double
        var originalImage: CGImage
        var rectifiedImage: CGImage
        var dewarpedImage: CGImage
        /// 纸张增强：当前选择的档位说明。
        var paperEnhanceTitle: String
        /// 全分辨率增强耗时（毫秒）。
        var paperEnhanceMilliseconds: Double
        /// 全分辨率增强结果（当前选择档；关闭时 = 去畸变结果）。
        var paperEnhancedImage: CGImage
        /// 各档位预览（关闭 / 255 / 310 × 白 / 米白 / 暖黄），降采样后并列展示。
        var paperEnhancePreviews: [PaperEnhancePreview]
        /// 检测到的四角（归一化）；nil = 未检测到（视图据此画叠加框）。
        var detectionQuad: DocumentQuad?
    }

    enum DewarpSelfTestError: Error, CustomStringConvertible {
        case sampleImageMissing
        case imageConversionFailed
        case imageRenderFailed
        case backendMissing
        case photoDataMissing
        case sourceTooLarge(width: Int, height: Int)

        var description: String {
            switch self {
            case .sampleImageMissing: return "bundle 内找不到样例图 DevSampleDocument（检查 Resources/ 是否入库）"
            case .imageConversionFailed: return "图片转换 Float32 失败"
            case .imageRenderFailed: return "去畸变结果转 CGImage 失败"
            case .backendMissing: return "组合根未装配去畸变后端（模型不可用）"
            case .photoDataMissing: return "相册条目取不到图片数据（可能是 iCloud 未下载完成或条目已失效）"
            case let .sourceTooLarge(width, height):
                return "源图过大（\(width)×\(height) 超过向量化重采样上限 \(GridResampler.maximumSourcePixelCount) 像素）"
            }
        }
    }

    /// 自测管线。**非主线程可调用**（视图用 `Task.detached` 调用）。
    enum DewarpSelfTestRunner {
        /// 样例图资源名（带扩展名，便于报错文案定位）。
        static let sampleResource = "DevSampleDocument.jpg"
        private static let sampleResourceBaseName = "DevSampleDocument"

        /// 读入内置样例图——与相册照片走同一条读入路径（含降采样与耗时口径）。
        static func loadSamplePhoto() throws -> DevPhotoLoadResult {
            guard let url = Bundle.main.url(forResource: sampleResourceBaseName, withExtension: "jpg") else {
                throw DewarpSelfTestError.sampleImageMissing
            }
            return try DevPhotoLoader.load(data: Data(contentsOf: url))
        }

        /// 跑一次完整自测：检测 → 透视矫正 → 预处理 → N 次推理（计时）→ 全分辨率重采样 → 组装报告。
        ///
        /// - Parameter progress: 阶段回报（在调用线程上同步调用；视图侧负责切到主线程刷 UI）。
        /// - Throws: `CancellationError`（取消）；其余为真实失败原因。
        static func run(
            photo: DevPhotoLoadResult,
            sourceLabel: String,
            detector: ImageDocumentDetecting,
            corrector: CoreImagePerspectiveCorrector,
            predictor: GridPredicting,
            descriptor: DewarpModelDescriptor,
            modelStatus: String,
            computeUnits: String,
            device: String,
            iterations: Int,
            paperSelection: PaperEnhanceSelection = PaperEnhanceSelection(),
            progress: @Sendable (DewarpSelfTestStage) -> Void = { _ in }
        ) throws -> DewarpSelfTestReport {
            try Task.checkCancellation()

            // 大图守卫：向量化重采样要求源平面像素数 ≤ 2^24（超上限明确报错，不静默卡死）。
            let pixelCount = photo.image.width * photo.image.height
            guard pixelCount <= GridResampler.maximumSourcePixelCount else {
                throw DewarpSelfTestError.sourceTooLarge(width: photo.image.width, height: photo.image.height)
            }

            // ① 文档检测（像素 → 四角 + 置信度）；失败即回退整帧。
            progress(.detecting)
            let detectionStart = CFAbsoluteTimeGetCurrent()
            var detection: DocumentDetection?
            var detectionStatus: String
            do {
                let result = try detector.detectDocument(in: photo.image)
                detection = result
                detectionStatus = String(format: "已检测到文档（置信度 %.3f）", result.confidence)
            } catch {
                detectionStatus = "未检测到文档（已回退：整帧直接去畸变）· \(error)"
            }
            let detectionMilliseconds = (CFAbsoluteTimeGetCurrent() - detectionStart) * 1000
            try Task.checkCancellation()

            // ② 前段决策（检测 + 矫正方案）：**永不抛错**，退化/缺失一律回退整帧。
            let sourceSize = CGSize(width: photo.image.width, height: photo.image.height)
            let decision = FrontEndPlanner.decide(detection: detection, sourceSize: sourceSize)
            if decision.detection != nil, decision.isFallback {
                detectionStatus += "（四角退化，已回退整帧）"
            }

            // ③ 透视矫正 + 裁切（全分辨率）；决策为回退时用整帧。
            progress(.rectifying)
            let rectificationStart = CFAbsoluteTimeGetCurrent()
            var rectifiedImage = photo.image
            var rectifiedSize = "\(photo.image.width)×\(photo.image.height)（未裁切，已回退）"
            if let plan = decision.rectification, let quad = decision.detection?.quad {
                do {
                    let corrected = try corrector.correctedImage(from: photo.image, quad: quad)
                    rectifiedImage = corrected
                    rectifiedSize = "\(corrected.width)×\(corrected.height)（目标 \(plan.targetWidth)×\(plan.targetHeight)）"
                } catch {
                    rectifiedSize = "矫正渲染失败（已回退整帧）：\(error)"
                }
            }
            let rectificationMilliseconds = (CFAbsoluteTimeGetCurrent() - rectificationStart) * 1000
            try Task.checkCancellation()

            // ④ 预处理（缩放到模型输入尺寸）。
            progress(.preprocessing)
            let preprocessStart = CFAbsoluteTimeGetCurrent()
            let input: FloatImage
            do {
                input = try FloatImageConverter.rgb(
                    from: rectifiedImage,
                    width: descriptor.inputWidth,
                    height: descriptor.inputHeight
                )
            } catch {
                throw DewarpSelfTestError.imageConversionFailed
            }
            let preprocess = (CFAbsoluteTimeGetCurrent() - preprocessStart) * 1000
            try Task.checkCancellation()

            // ⑤ N 次推理（逐轮回报进度 + 每轮前后可取消），取最后一次的网格。
            let runs = max(iterations, 1)
            var timings = [Double]()
            timings.reserveCapacity(runs)
            var grid: NormalizedSampleGrid?
            let totalStart = CFAbsoluteTimeGetCurrent()
            try StagedLoop.run(iterations: runs, onProgress: { completed, total in
                progress(.inference(completed: completed, total: total))
            }, body: { _ in
                let start = CFAbsoluteTimeGetCurrent()
                let predicted = try predictor.predictGrid(for: input)
                timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                grid = predicted
            })
            let inferenceTotal = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
            guard let grid else { throw DewarpSelfTestError.backendMissing }

            // ⑥ 上游 demo.py 的契约：网络在模型尺寸上出网格，**重采样在原（已矫正）图分辨率上做**。
            progress(.resampling)
            let resampleStart = CFAbsoluteTimeGetCurrent()
            let fullImage: FloatImage
            do {
                fullImage = try FloatImageConverter.rgb(
                    from: rectifiedImage,
                    width: rectifiedImage.width,
                    height: rectifiedImage.height
                )
            } catch {
                throw DewarpSelfTestError.imageConversionFailed
            }
            // 批 20：模型网格常只覆盖源图一个子矩形（内缩 1.3%–6.0%），直接按源图尺寸重采样会裁掉四边
            // （大象实测「最下面给裁切掉了一部分」）。先扩展成覆盖整幅源图 [-1,1]² 的网格再重采样；
            // 网格已覆盖时该调用是无副作用 no-op（恒等 / 铺满的网格逐点不变）。
            let coveringGrid = grid.extendedToCoverSource()
            AppLog.debug(
                "去畸变网格覆盖整幅源图：\(grid.columns)×\(grid.rows) → \(coveringGrid.columns)×\(coveringGrid.rows)",
                category: .dewarp
            )
            let dewarped = GridResampler.resample(grid: coveringGrid, source: fullImage)
            let resample = (CFAbsoluteTimeGetCurrent() - resampleStart) * 1000
            guard let dewarpedImage = FloatImageConverter.makeCGImage(from: dewarped) else {
                throw DewarpSelfTestError.imageRenderFailed
            }

            // ⑦ 纸张增强（去折痕 / 提白 / 换纸色）：全分辨率一档 + 各档位降采样预览并列。
            progress(.enhancing)
            let enhanceStart = CFAbsoluteTimeGetCurrent()
            let paperOptions = paperSelection.options
            let enhanced = paperOptions == nil
                ? dewarped
                : PaperEnhancer.enhance(dewarped, options: paperOptions)
            guard let enhancedImage = FloatImageConverter.makeCGImage(from: enhanced) else {
                throw DewarpSelfTestError.imageRenderFailed
            }
            let previews = paperEnhancePreviews(source: dewarpedImage)
            let enhanceMilliseconds = (CFAbsoluteTimeGetCurrent() - enhanceStart) * 1000
            progress(.finished)

            let sorted = timings.sorted()
            return DewarpSelfTestReport(
                modelStatus: modelStatus,
                computeUnits: computeUnits,
                device: device,
                sourceLabel: sourceLabel,
                sourceSize: photo.sourceSizeText,
                loadedSize: photo.loadedSizeText,
                loadMilliseconds: photo.loadMilliseconds,
                detectionStatus: detectionStatus,
                detectionMilliseconds: detectionMilliseconds,
                rectificationMilliseconds: rectificationMilliseconds,
                rectifiedSize: rectifiedSize,
                iterations: runs,
                inputSize: "\(descriptor.inputWidth)×\(descriptor.inputHeight)",
                gridSize: "\(grid.columns)×\(grid.rows) → \(coveringGrid.columns)×\(coveringGrid.rows)（覆盖整幅源图）",
                preprocessMilliseconds: preprocess,
                inferenceMinimumMilliseconds: sorted.first ?? 0,
                inferenceMedianMilliseconds: sorted[sorted.count / 2],
                inferenceMaximumMilliseconds: sorted.last ?? 0,
                inferenceTotalMilliseconds: inferenceTotal,
                resampleMilliseconds: resample,
                originalImage: photo.image,
                rectifiedImage: rectifiedImage,
                dewarpedImage: dewarpedImage,
                paperEnhanceTitle: paperSelection.title,
                paperEnhanceMilliseconds: enhanceMilliseconds,
                paperEnhancedImage: enhancedImage,
                paperEnhancePreviews: previews,
                detectionQuad: decision.detection?.quad
            )
        }

        /// 各档位预览：先把去畸变结果降采样到显示尺寸，再逐档增强。
        /// 全分辨率那一档单独计时（这里只为并列对比，输入分辨率更低、耗时不作产品口径）。
        private static func paperEnhancePreviews(source: CGImage) -> [PaperEnhancePreview] {
            let longSide: CGFloat = 420
            let longest = CGFloat(max(source.width, source.height))
            let scale = longest > longSide ? longSide / longest : 1
            let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
            let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
            guard let small = try? FloatImageConverter.rgb(from: source, width: width, height: height) else {
                return []
            }
            var previews = [PaperEnhancePreview]()
            for whiteness in PaperWhitenessChoice.allCases {
                for color in PaperColorPreset.allCases {
                    let selection = PaperEnhanceSelection(whiteness: whiteness, color: color)
                    let options = selection.options
                    let enhanced = options == nil ? small : PaperEnhancer.enhance(small, options: options)
                    guard let image = FloatImageConverter.makeCGImage(from: enhanced) else { continue }
                    previews.append(PaperEnhancePreview(title: selection.title, image: image))
                }
            }
            return previews
        }
    }
#endif
