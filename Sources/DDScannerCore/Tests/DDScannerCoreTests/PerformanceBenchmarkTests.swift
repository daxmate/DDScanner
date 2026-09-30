// 性能基准 harness（本机 macOS 可直接跑，默认不开、不进 CI）。
//
// 跑法（**必须用 release 配置**，与真机 Release 构建同口径）：
//   DDSCANNER_BENCH=1 swift test -c release --package-path Sources/DDScannerCore \
//       --filter PerformanceBenchmarkTests
// 输出到 stderr（产品代码禁裸 print，测试文件同受该扫描约束，故走 FileHandle）。
//
// 量的是三件与本批目标对应的事，每件都给「产品路径 vs 参考实现」两个数：
//   ① 全分辨率重采样 GridResampler.resample（真机 1548.14 ms 那一项里的主要部分）；
//   ② 全分辨率 CGImage → Float32（旧实现在自测页里把它算进"重采样"计时器内）；
//   ③ 预处理缩放到 488×712（真机 66.89 ms 那一项）。
// 注意：**本机数字 ≠ 真机数字**，真机数据只能由用户在真机上跑；这里只用于改动前后同口径对比。
import CoreGraphics
import DDScannerCore
import Foundation
import Testing

@Suite("PerformanceBenchmark")
struct PerformanceBenchmarkTests {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DDSCANNER_BENCH"] == "1"
    }

    @Test(
        "改动前后同口径基准（DDSCANNER_BENCH=1 时跑）",
        .enabled(if: PerformanceBenchmarkTests.isEnabled)
    )
    func benchmarkStages() throws {
        emit("config=\(configuration) bench-env=DDSCANNER_BENCH=1")

        // ① 重采样：两档真实尺寸 + 真实量级的 31×45 弯曲网格
        for (width, height) in [(3024, 4032), (1102, 1802)] {
            let source = Self.floatImage(width: width, height: height)
            let grid = Self.warpedGrid()
            let iterations = width > 2000 ? 3 : 5
            measure(
                "resample product  \(width)x\(height)x3",
                iterations: iterations
            ) {
                _ = GridResampler.resample(
                    grid: grid, source: source, targetWidth: width, targetHeight: height
                )
            }
            measure(
                "resample reference \(width)x\(height)x3",
                iterations: iterations
            ) {
                _ = ScalarGridResamplerReference.resample(
                    grid: grid, source: source, targetWidth: width, targetHeight: height
                )
            }

            // ② + ③ 位图路径（CGImage → Float32：全分辨率转换 + 预处理缩放）。
            //    每轮用**新造**的位图：CoreGraphics / vImage 都会缓存同一张图的渲染结果，
            //    反复画同一张会量到缓存命中（实测差 30 倍），那样两边都不真实。
            let images = (0 ..< iterations).map { Self.cgImage(width: width, height: height, seed: $0) }
            measureCold("fullres-convert product   \(width)x\(height)", images: images) { image in
                _ = try? FloatImageConverter.rgb(from: image, width: width, height: height)
            }
            measureCold("fullres-convert reference \(width)x\(height)", images: images) { image in
                _ = try? LegacyFloatImageReference.rgb(from: image, width: width, height: height)
            }
            measureCold("preprocess product   488x712 from \(width)x\(height)", images: images) { image in
                _ = try? FloatImageConverter.rgb(from: image, width: 488, height: 712)
            }
            measureCold("preprocess reference 488x712 from \(width)x\(height)", images: images) { image in
                _ = try? LegacyFloatImageReference.rgb(from: image, width: 488, height: 712)
            }
        }
    }

    // MARK: - 计时与输出

    private var configuration: String {
        #if DEBUG
            return "debug"
        #else
            return "release"
        #endif
    }

    private func measure(_ label: String, iterations: Int, _ body: () -> Void) {
        var timings = [Double]()
        timings.reserveCapacity(iterations)
        for _ in 0 ..< iterations {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        report(label, timings: timings)
    }

    /// 每轮一张**新位图**（避开 CoreGraphics / vImage 的同图渲染缓存）。
    private func measureCold(_ label: String, images: [CGImage], _ body: (CGImage) -> Void) {
        var timings = [Double]()
        timings.reserveCapacity(images.count)
        for image in images {
            let start = CFAbsoluteTimeGetCurrent()
            body(image)
            timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        report(label, timings: timings)
    }

    private func report(_ label: String, timings: [Double]) {
        let sorted = timings.sorted()
        let minimum = sorted.first ?? 0
        let median = sorted[sorted.count / 2]
        let maximum = sorted.last ?? 0
        emit(
            String(
                format: "%@  min=%.2fms median=%.2fms max=%.2fms n=%d",
                label, minimum, median, maximum, timings.count
            )
        )
    }

    private func emit(_ line: String) {
        FileHandle.standardError.write(Data(("[BENCH] " + line + "\n").utf8))
    }

    // MARK: - 测试输入

    /// 确定性图案图（横渐变 + 纵渐变 + 棋盘，三通道）。
    private static func floatImage(width: Int, height: Int) -> FloatImage {
        let plane = width * height
        var values = [Float](repeating: 0, count: plane * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x
                values[index] = Float(x) / Float(width - 1)
                values[plane + index] = Float(y) / Float(height - 1)
                values[2 * plane + index] = ((x / 3 + y / 5) % 2 == 0) ? 0.3 : 0.7
            }
        }
        return FloatImage(width: width, height: height, channels: 3, values: values)
    }

    /// 确定性位图（同图案的 8bit 版），用于量「CGImage → Float32」与「预处理」。
    /// `seed` 只做微小扰动：每张图内容不同 → 不会被 CoreGraphics 的同图缓存命中。
    private static func cgImage(width: Int, height: Int, seed: Int) -> CGImage {
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 255, count: bytesPerRow * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let pixel = y * bytesPerRow + x * 4
                buffer[pixel] = UInt8((x * 255 + seed) / max(width - 1, 1))
                buffer[pixel + 1] = UInt8((y * 255 + seed) / max(height - 1, 1))
                buffer[pixel + 2] = ((x / 3 + y / 5 + seed) % 2 == 0) ? 80 : 180
            }
        }
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        buffer.withUnsafeMutableBytes { raw in
            context.data?.copyMemory(from: raw.baseAddress!, byteCount: bytesPerRow * height)
        }
        return context.makeImage()!
    }

    /// 平滑弯曲网格（31×45，与 UVDoc 产物同量级）。
    private static func warpedGrid(columns: Int = 31, rows: Int = 45) -> NormalizedSampleGrid {
        var xValues = [Float]()
        var yValues = [Float]()
        for row in 0 ..< rows {
            let v = Float(row) / Float(rows - 1)
            for column in 0 ..< columns {
                let u = Float(column) / Float(columns - 1)
                xValues.append(min(max(u * 2 - 1 + 0.06 * sin(v * 3.1), -1), 1))
                yValues.append(min(max(v * 2 - 1 + 0.05 * cos(u * 2.7), -1), 1))
            }
        }
        return NormalizedSampleGrid(columns: columns, rows: rows, xValues: xValues, yValues: yValues)
    }
}
