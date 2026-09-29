// 开发用去畸变自测：跑模型、计时、出对比图（仅 DEBUG 编译；见 docs/device-test-uvdoc.md）。
//
// 这里只做「把已有后端跑起来并如实汇报」的事：不构造任何实现（依赖由组合根经 Environment 注入），
// 也不做相机/拍摄——那是后续批次。
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

        var description: String {
            switch self {
            case .sampleImageMissing: return "bundle 内找不到样例图 DevSampleDocument（检查 Resources/ 是否入库）"
            case .imageConversionFailed: return "样例图转换 Float32 失败"
            case .imageRenderFailed: return "去畸变结果转 CGImage 失败"
            case .backendMissing: return "组合根未装配去畸变后端（模型不可用）"
            }
        }
    }

    @MainActor
    enum DewarpSelfTestRunner {
        /// 样例图资源名（带扩展名，避免 `UIImage(named:)` 猜扩展名失败）。
        static let sampleResource = "DevSampleDocument.jpg"
        /// 跑一次完整自测：预处理 → N 次推理（计时）→ 全分辨率重采样 → 组装报告。
        static func run(
            predictor: GridPredicting,
            descriptor: DewarpModelDescriptor,
            modelStatus: String,
            computeUnits: String,
            iterations: Int
        ) throws -> DewarpSelfTestReport {
            guard let original = UIImage(named: sampleResource) else { throw DewarpSelfTestError.sampleImageMissing }

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
        func floatImage(width: Int, height: Int) throws -> FloatImage {
            guard let image = cgImage else { throw DewarpSelfTestError.imageConversionFailed }
            let bytesPerRow = width * 4
            var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
            let rendered: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { throw DewarpSelfTestError.imageConversionFailed }

            let plane = width * height
            var values = [Float](repeating: 0, count: plane * 3)
            for index in 0 ..< plane {
                let pixel = index * 4
                values[index] = Float(buffer[pixel]) / 255
                values[plane + index] = Float(buffer[pixel + 1]) / 255
                values[2 * plane + index] = Float(buffer[pixel + 2]) / 255
            }
            return FloatImage(width: width, height: height, channels: 3, values: values)
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
