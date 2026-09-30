// 「透视矫正 + 裁切」（`correctedImage`）的四段分解计时基准（批 9，本机 macOS，默认不开、不进 CI）。
//
// 跑法（**Debug 与 Release 各跑一次**；发布版口径是 Release）：
//   DDSCANNER_BENCH=1 swift test --package-path Sources/DDScannerCore \
//       --filter RectificationDecomposition
//   DDSCANNER_BENCH=1 swift test -c release --package-path Sources/DDScannerCore \
//       --filter RectificationDecomposition
//
// 量的是真机 7107 ms 那一项被拆开的四段（同一输入、同尺寸口径）：
//   (a) `FloatImageConverter.rgb`（整帧 3024×4032 → Float32）
//   (b) `DocumentRectifier.samplingGrid`（目标像素 → 源图采样坐标，2689×3007 ≈ 8.08 M 点）
//   (c) `GridResampler.resample`（按网格采样到目标分辨率）
//   (d) `FloatImageConverter.makeCGImage`（Float32 → CGImage）
// 另给一条 (a)+(b)+(c)+(d) 顺序跑的合计（与 `CoreImagePerspectiveCorrector.correctedImage` 同序）。
//
// 注意：**本机数字 ≠ 真机数字**；真机数据只能由用户在真机上跑。这里只做改动前后同口径对比。
import Accelerate
import CoreGraphics
import Foundation
import Testing
@testable import DDScannerCore

@Suite("RectificationDecomposition")
struct RectificationDecompositionBenchmarkTests {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DDSCANNER_BENCH"] == "1"
    }

    /// 真机自测页口径：载入 3024×4032，检测四角决定的输出 ≈ 2689×3007。
    private static let sourceWidth = 3024
    private static let sourceHeight = 4032
    private static let targetWidth = 2689
    private static let targetHeight = 3007

    @Test(
        "四段分解计时（DDSCANNER_BENCH=1 时跑）",
        .enabled(if: RectificationDecompositionBenchmarkTests.isEnabled)
    )
    func decompose() throws {
        emit("config=\(configuration) source=\(Self.sourceWidth)x\(Self.sourceHeight) target=\(Self.targetWidth)x\(Self.targetHeight)")

        let image = Self.cgImage(width: Self.sourceWidth, height: Self.sourceHeight)
        let quad = Self.quad(yielding: CGSize(width: Self.targetWidth, height: Self.targetHeight))

        // 预热：vImage / CoreGraphics 首次调用有一次性开销，不计入稳态数字。
        _ = try? FloatImageConverter.rgb(from: image, width: 128, height: 128)

        // (a) 整帧 → Float32
        var source: FloatImage?
        measure("(a) FloatImageConverter.rgb 整帧", iterations: 3) {
            source = try? FloatImageConverter.rgb(
                from: image, width: Self.sourceWidth, height: Self.sourceHeight
            )
        }
        let fullSource = try #require(source)

        // 单应（只解一次；`plan` 的开销不含在本段内）
        let plan = try DocumentRectifier.plan(quad: quad, sourceSize: CGSize(width: Self.sourceWidth, height: Self.sourceHeight))
        #expect(plan.targetWidth == Self.targetWidth && plan.targetHeight == Self.targetHeight)
        guard let homographyValues = Homography.solve(source: DocumentRectifier.unitSquareCorners, targets: quad.points) else {
            Issue.record("单应求解失败，基准无法继续")
            return
        }
        let homography = Homography(values: homographyValues)

        // (b) 采样网格生成
        measure("(b) DocumentRectifier.samplingGrid", iterations: 3) {
            _ = DocumentRectifier.samplingGrid(
                homography: homography, targetWidth: Self.targetWidth, targetHeight: Self.targetHeight
            )
        }
        measure("(b0) ScalarSamplingGridReference（改动前口径）", iterations: 2) {
            _ = ScalarSamplingGridReference.samplingGrid(
                homography: homography, targetWidth: Self.targetWidth, targetHeight: Self.targetHeight
            )
        }
        let grid = DocumentRectifier.samplingGrid(
            homography: homography, targetWidth: Self.targetWidth, targetHeight: Self.targetHeight
        )

        // (c) 重采样
        var rectified: FloatImage?
        measure("(c) GridResampler.resample", iterations: 3) {
            rectified = GridResampler.resample(
                grid: grid, source: fullSource, targetWidth: Self.targetWidth, targetHeight: Self.targetHeight
            )
        }
        let fullRectified = try #require(rectified)

        // (d) Float32 → CGImage
        var output: CGImage?
        measure("(d) FloatImageConverter.makeCGImage", iterations: 3) {
            output = FloatImageConverter.makeCGImage(from: fullRectified)
        }
        #expect(output != nil)
        measure("(d0) LegacyFloatImageReference.pixelBuffer（改动前口径）", iterations: 2) {
            _ = LegacyFloatImageReference.pixelBuffer(from: fullRectified)
        }

        // 合计：(a)+(b)+(c)+(d) 顺序跑一遍（与 correctedImage 同序）
        measure("(a+b+c+d) 合计 correctedImage 同序", iterations: 3) {
            guard
                let frame = try? FloatImageConverter.rgb(
                    from: image, width: Self.sourceWidth, height: Self.sourceHeight
                ),
                let grid = try? DocumentRectifier.plan(
                    quad: quad, sourceSize: CGSize(width: Self.sourceWidth, height: Self.sourceHeight)
                ).samplingGrid
            else {
                Issue.record("合计基准前置步骤失败")
                return
            }
            let sampled = GridResampler.resample(
                grid: grid, source: frame, targetWidth: Self.targetWidth, targetHeight: Self.targetHeight
            )
            _ = FloatImageConverter.makeCGImage(from: sampled)
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

    /// 轴对齐四角，使目标尺寸恰为期望的像素宽高（宽度按左右对边最大像素长取整）。
    private static func quad(yielding size: CGSize) -> DocumentQuad {
        let widthRatio = Double(size.width) / Double(sourceWidth)
        let heightRatio = Double(size.height) / Double(sourceHeight)
        return DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: widthRatio, y: 0),
            bottomRight: CGPoint(x: widthRatio, y: heightRatio),
            bottomLeft: CGPoint(x: 0, y: heightRatio)
        )
    }

    /// 确定性位图（横向渐变 + 纵向渐变 + 棋盘），不依赖随机数种子。
    private static func cgImage(width: Int, height: Int) -> CGImage {
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 255, count: bytesPerRow * height)
        let rScale = 255.0 / Double(max(width - 1, 1))
        let gScale = 255.0 / Double(max(height - 1, 1))
        for y in 0 ..< height {
            let green = UInt8(min(255, Double(y) * gScale))
            let rowBase = y * bytesPerRow
            for x in 0 ..< width {
                let pixel = rowBase + x * 4
                buffer[pixel] = UInt8(min(255, Double(x) * rScale))
                buffer[pixel + 1] = green
                buffer[pixel + 2] = ((x / 3 + y / 5) % 2 == 0) ? 80 : 180
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
}
