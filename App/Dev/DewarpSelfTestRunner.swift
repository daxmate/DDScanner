// 开发用去畸变自测：跑模型、计时、出对比图（仅 DEBUG 编译；见 docs/device-test-uvdoc.md）。
//
// 这里只做「把已有后端跑起来并如实汇报」的事：不构造任何实现（依赖由组合根经 Environment 注入），
// 也不做相机/拍摄——那是后续批次。
//
// 图像来源有两处：内置样例（bundle）与相册照片（PhotosPicker）。两者都经 `DevPhotoLoader`
// 读入，再走**完全同一条**管线（预处理 → N 次推理计时 → 全分辨率重采样）。
#if DEBUG
    import CoreGraphics
    import CoreML
    import DDScannerCore
    import DDScannerDewarp
    import Foundation
    import UIKit

    /// 一次自测的完整结果（视图只负责展示）。
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
        var iterations: Int
        var inputSize: String
        var gridSize: String
        var preprocessMilliseconds: Double
        var inferenceMinimumMilliseconds: Double
        var inferenceMedianMilliseconds: Double
        var inferenceMaximumMilliseconds: Double
        var inferenceTotalMilliseconds: Double
        var resampleMilliseconds: Double
        var originalImage: UIImage
        var dewarpedImage: UIImage
    }

    enum DewarpSelfTestError: Error, CustomStringConvertible {
        case sampleImageMissing
        case imageConversionFailed
        case imageRenderFailed
        case backendMissing
        case photoDataMissing

        var description: String {
            switch self {
            case .sampleImageMissing: return "bundle 内找不到样例图 DevSampleDocument（检查 Resources/ 是否入库）"
            case .imageConversionFailed: return "图片转换 Float32 失败"
            case .imageRenderFailed: return "去畸变结果转 CGImage 失败"
            case .backendMissing: return "组合根未装配去畸变后端（模型不可用）"
            case .photoDataMissing: return "相册条目取不到图片数据（可能是 iCloud 未下载完成或条目已失效）"
            }
        }
    }

    @MainActor
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

        /// 跑一次完整自测：预处理 → N 次推理（计时）→ 全分辨率重采样 → 组装报告。
        static func run(
            photo: DevPhotoLoadResult,
            sourceLabel: String,
            predictor: GridPredicting,
            descriptor: DewarpModelDescriptor,
            modelStatus: String,
            computeUnits: String,
            iterations: Int
        ) throws -> DewarpSelfTestReport {
            let original = UIImage(cgImage: photo.image)

            let preprocessStart = CFAbsoluteTimeGetCurrent()
            let input = try original.floatImage(width: descriptor.inputWidth, height: descriptor.inputHeight)
            let preprocess = (CFAbsoluteTimeGetCurrent() - preprocessStart) * 1000

            let runs = max(iterations, 1)
            var timings = [Double]()
            timings.reserveCapacity(runs)
            var grid: NormalizedSampleGrid?
            let totalStart = CFAbsoluteTimeGetCurrent()
            for _ in 0 ..< runs {
                let start = CFAbsoluteTimeGetCurrent()
                let predicted = try predictor.predictGrid(for: input)
                timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                grid = predicted
            }
            let inferenceTotal = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
            guard let grid else { throw DewarpSelfTestError.backendMissing }

            // 上游 demo.py 的契约：网络在模型尺寸上出网格，**重采样在原图分辨率上做**。
            let resampleStart = CFAbsoluteTimeGetCurrent()
            let size = original.pixelSize
            let fullImage = try original.floatImage(width: size.width, height: size.height)
            let dewarped = GridResampler.resample(grid: grid, source: fullImage)
            let resample = (CFAbsoluteTimeGetCurrent() - resampleStart) * 1000
            guard let dewarpedImage = dewarped.makeUIImage() else { throw DewarpSelfTestError.imageRenderFailed }

            let sorted = timings.sorted()
            return DewarpSelfTestReport(
                modelStatus: modelStatus,
                computeUnits: computeUnits,
                device: DeviceDescription.current,
                sourceLabel: sourceLabel,
                sourceSize: photo.sourceSizeText,
                loadedSize: photo.loadedSizeText,
                loadMilliseconds: photo.loadMilliseconds,
                iterations: runs,
                inputSize: "\(descriptor.inputWidth)×\(descriptor.inputHeight)",
                gridSize: "\(grid.columns)×\(grid.rows)",
                preprocessMilliseconds: preprocess,
                inferenceMinimumMilliseconds: sorted.first ?? 0,
                inferenceMedianMilliseconds: sorted[sorted.count / 2],
                inferenceMaximumMilliseconds: sorted.last ?? 0,
                inferenceTotalMilliseconds: inferenceTotal,
                resampleMilliseconds: resample,
                originalImage: original,
                dewarpedImage: dewarpedImage
            )
        }
    }

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

    extension UIImage {
        /// 逻辑像素尺寸（用 CGImage 的真实像素尺寸，避免 scale 误差）。
        var pixelSize: (width: Int, height: Int) {
            guard let image = cgImage else {
                return (max(Int(size.width * scale), 1), max(Int(size.height * scale), 1))
            }
            return (image.width, image.height)
        }

        /// 缩放到指定尺寸并转成 Float32 RGB（[0,1]）平面图。
        /// 具体转换已下沉到 Core 的 `FloatImageConverter`（vImage，向量化）。
        func floatImage(width: Int, height: Int) throws -> FloatImage {
            guard let image = cgImage else { throw DewarpSelfTestError.imageConversionFailed }
            do {
                return try FloatImageConverter.rgb(from: image, width: width, height: height)
            } catch {
                throw DewarpSelfTestError.imageConversionFailed
            }
        }
    }

    extension FloatImage {
        /// Float32 平面图 → CGImage（仅用于自测页预览）。
        func makeUIImage() -> UIImage? {
            let plane = width * height
            var buffer = [UInt8](repeating: 255, count: plane * 4)
            for index in 0 ..< plane {
                let pixel = index * 4
                for channel in 0 ..< min(channels, 3) {
                    let value = values[channel * plane + index]
                    buffer[pixel + channel] = UInt8(max(0, min(255, value * 255)).rounded())
                }
            }
            guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            guard let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            ) else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }
#endif
