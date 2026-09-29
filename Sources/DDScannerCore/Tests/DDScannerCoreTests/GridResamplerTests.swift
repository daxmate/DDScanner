// GridResampler 纯逻辑测试（本机 `swift test` 可跑，无模拟器）。
// 覆盖：identity / 人工算例 / 边界 clamp / 退化输入 / Float32 精度守卫 / 多通道 / 网格插值。
import Testing
@testable import DDScannerCore

@Suite("GridResampler")
struct GridResamplerTests {
    /// 由行优先的二维数组构造单通道图（rows = y，元素 = x）。
    private func grayscale(_ rows: [[Float]]) -> FloatImage {
        let height = rows.count
        let width = rows[0].count
        return FloatImage(width: width, height: height, channels: 1, values: rows.flatMap { $0 })
    }

    /// 2×2 手工算例：[[0, 1], [2, 3]]，即 (x,y) → 0, 1 / 2, 3。
    private var twoByTwo: FloatImage { grayscale([[0, 1], [2, 3]]) }

    private func pixel(_ image: FloatImage, _ x: Int, _ y: Int) -> Float {
        image.value(x: x, y: y, channel: 0) ?? .nan
    }

    // MARK: identity

    @Test("identity 网格 + 同分辨率 → 逐像素等于原图")
    func identityAtSameResolution() {
        let source = grayscale([[0, 1, 2], [3, 4, 5], [6, 7, 8]])
        let output = GridResampler.resample(grid: .identity(columns: 3, rows: 3), source: source)
        #expect(output.width == 3 && output.height == 3)
        for row in 0 ..< 3 {
            for column in 0 ..< 3 {
                #expect(abs(pixel(output, column, row) - pixel(source, column, row)) < 1e-6)
            }
        }
    }

    @Test("2×2 identity 网格插值到全分辨率 → 仍等于原图（线性函数插值精确）")
    func identityFromCoarseGrid() {
        let source = grayscale([
            [0, 1, 2, 3],
            [4, 5, 6, 7],
            [8, 9, 10, 11],
        ])
        let output = GridResampler.resample(grid: .identity(columns: 2, rows: 2), source: source)
        for row in 0 ..< 3 {
            for column in 0 ..< 4 {
                #expect(abs(pixel(output, column, row) - pixel(source, column, row)) < 1e-5)
            }
        }
    }

    // MARK: 人工算例

    @Test("四角网格 + 原分辨率 → 逐像素等于原图")
    func cornersMapToCorners() {
        let grid = NormalizedSampleGrid(
            columns: 2,
            rows: 2,
            xValues: [-1, 1, -1, 1],
            yValues: [-1, -1, 1, 1]
        )
        let output = GridResampler.resample(grid: grid, source: twoByTwo)
        #expect(pixel(output, 0, 0) == 0)
        #expect(pixel(output, 1, 0) == 1)
        #expect(pixel(output, 0, 1) == 2)
        #expect(pixel(output, 1, 1) == 3)
    }

    @Test("全零网格（单一坐标 0,0）→ 每个像素取图像中心的双线性均值")
    func centerSample() {
        // (0,0) → 像素 (0.5, 0.5) → 0.25 × (0 + 1 + 2 + 3) = 1.5
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [0], yValues: [0])
        let output = GridResampler.resample(grid: grid, source: twoByTwo, targetWidth: 2, targetHeight: 2)
        for row in 0 ..< 2 {
            for column in 0 ..< 2 {
                #expect(abs(pixel(output, column, row) - 1.5) < 1e-6)
            }
        }
    }

    @Test("非中心坐标 → 单轴双线性混合（人工算）")
    func halfWayOnTopEdge() {
        // (0, -1) → 像素 (0.5, 0) → 0.5 × (0 + 1) = 0.5
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [0], yValues: [-1])
        let output = GridResampler.resample(grid: grid, source: twoByTwo, targetWidth: 1, targetHeight: 1)
        #expect(abs(pixel(output, 0, 0) - 0.5) < 1e-6)
    }

    @Test("非整数采样点 → 四邻域按分数加权")
    func quarterSample() {
        // (0.5, 0.5) → 像素 (0.75, 0.75) → 0.75/0.75 混合 = 2.25
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [0.5], yValues: [0.5])
        let output = GridResampler.resample(grid: grid, source: twoByTwo, targetWidth: 1, targetHeight: 1)
        #expect(abs(pixel(output, 0, 0) - 2.25) < 1e-6)
    }

    // MARK: 边界

    @Test("越界网格坐标被 clamp 到边缘像素（不做零填充）")
    func outOfRangeClampsToEdge() {
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [-3], yValues: [5])
        let output = GridResampler.resample(grid: grid, source: twoByTwo, targetWidth: 1, targetHeight: 1)
        // x → 像素 0，y → 像素 1 → 左下角值 2
        #expect(abs(pixel(output, 0, 0) - 2) < 1e-6)
    }

    @Test("非有限网格坐标按归一化 0 处理（不把 NaN 传进像素）")
    func nonFiniteCoordinateFallsBack() {
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [.nan], yValues: [.infinity])
        let output = GridResampler.resample(grid: grid, source: twoByTwo, targetWidth: 1, targetHeight: 1)
        // 两个坐标都回落到归一化 0 → 图像中心的双线性均值 1.5
        #expect(pixel(output, 0, 0).isNaN == false)
        #expect(abs(pixel(output, 0, 0) - 1.5) < 1e-6)
    }

    @Test("越界访问返回 nil，不越索引失效")
    func accessorsAreBoundsChecked() {
        #expect(twoByTwo.value(x: 2, y: 0, channel: 0) == nil)
        #expect(twoByTwo.value(x: 0, y: 0, channel: 1) == nil)
        #expect(NormalizedSampleGrid.identity(columns: 2, rows: 2).point(column: 2, row: 0) == nil)
    }

    // MARK: 退化输入

    @Test("1×1 网格可重采样到任意目标尺寸（不崩、不除零）")
    func singlePointGrid() {
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [0], yValues: [0])
        let output = GridResampler.resample(grid: grid, source: twoByTwo, targetWidth: 4, targetHeight: 3)
        #expect(output.width == 4 && output.height == 3)
        for row in 0 ..< 3 {
            for column in 0 ..< 4 {
                #expect(abs(pixel(output, column, row) - 1.5) < 1e-6)
            }
        }
    }

    @Test("1×1 网格插值到 2×2 → 四个点都等于该点")
    func singlePointGridUpsample() {
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [0.25], yValues: [-0.5])
        let upsampled = GridResampler.upsampleGrid(grid, columns: 2, rows: 2)
        for row in 0 ..< 2 {
            for column in 0 ..< 2 {
                let point = upsampled.point(column: column, row: row)
                #expect(point?.x == 0.25)
                #expect(point?.y == -0.5)
            }
        }
    }

    @Test("1×1 源图 → 任何网格都取该像素（不越界）")
    func singlePixelSource() {
        let source = grayscale([[7]])
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [-1], yValues: [1])
        let output = GridResampler.resample(grid: grid, source: source, targetWidth: 3, targetHeight: 2)
        for row in 0 ..< 2 {
            for column in 0 ..< 3 {
                #expect(pixel(output, column, row) == 7)
            }
        }
    }

    // MARK: Float32 精度守卫

    @Test("Float32 路径：1/3 的混合结果必须保真到 1e-6（FP16 会给 ~8e-5 的误差）")
    func retainsFloat32Precision() {
        // 源 2×1 = [0, 1]；网格 x = -1/3 → 像素坐标 1/3 → 结果应为 1/3。
        let source = grayscale([[0, 1]])
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [2.0 / 3.0 - 1], yValues: [0])
        let output = GridResampler.resample(grid: grid, source: source, targetWidth: 1, targetHeight: 1)
        #expect(abs(pixel(output, 0, 0) - Float(1.0 / 3.0)) < 1e-7)
    }

    @Test("Float32 路径：不会把像素量化到半精度格点")
    func pixelValueSurvivesUnchanged() {
        let source = grayscale([[0.33333334]])
        let output = GridResampler.resample(grid: .identity(columns: 1, rows: 1), source: source)
        #expect(pixel(output, 0, 0) == 0.33333334)
    }

    // MARK: 多通道

    @Test("RGB 三通道各自独立重采样")
    func channelsAreIndependent() {
        let red: [Float] = [0, 1, 2, 3]
        let green = red.map { $0 * 10 }
        let blue = red.map { $0 * 100 }
        let source = FloatImage(width: 2, height: 2, channels: 3, values: red + green + blue)
        let output = GridResampler.resample(grid: .identity(columns: 2, rows: 2), source: source)
        #expect(output.channels == 3)
        for row in 0 ..< 2 {
            for column in 0 ..< 2 {
                let index = row * 2 + column
                #expect(output.value(x: column, y: row, channel: 0) == red[index])
                #expect(output.value(x: column, y: row, channel: 1) == green[index])
                #expect(output.value(x: column, y: row, channel: 2) == blue[index])
            }
        }
    }

    // MARK: 网格插值（align_corners=True）

    @Test("identity 网格插值到 3×3 → 中点为 0,0，角点为 ±1")
    func upsampledGridIsLinear() {
        let upsampled = GridResampler.upsampleGrid(.identity(columns: 2, rows: 2), columns: 3, rows: 3)
        let center = upsampled.point(column: 1, row: 1)
        #expect(abs((center?.x ?? .nan) - 0) < 1e-6)
        #expect(abs((center?.y ?? .nan) - 0) < 1e-6)
        let corner = upsampled.point(column: 2, row: 2)
        #expect(abs((corner?.x ?? .nan) - 1) < 1e-6)
        #expect(abs((corner?.y ?? .nan) - 1) < 1e-6)
    }

    @Test("网格插值到目标分辨率：目标是源网格尺寸时逐点不变")
    func upsampleToSameSizeIsIdentity() {
        let grid = NormalizedSampleGrid(
            columns: 3,
            rows: 2,
            xValues: [-1, 0, 1, -1, 0.5, 1],
            yValues: [-1, -0.25, 0, 1, 0.25, 0]
        )
        let upsampled = GridResampler.upsampleGrid(grid, columns: 3, rows: 2)
        #expect(upsampled.xValues == grid.xValues)
        #expect(upsampled.yValues == grid.yValues)
    }

    @Test("归一化约定与 PyTorch 一致：-1 → 像素 0，+1 → 像素 (N-1)")
    func normalizationMatchesPyTorch() {
        let source = grayscale([[0, 1, 2, 3]])
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [1], yValues: [0])
        let output = GridResampler.resample(grid: grid, source: source, targetWidth: 1, targetHeight: 1)
        #expect(pixel(output, 0, 0) == 3)
    }
}
