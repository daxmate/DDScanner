// GridResample 等价性契约：向量化实现（产品路径）vs 标量实现（测试侧参考实现）。
//
// 阈值 1e-3 的依据：两条路径的算式完全相同，只有累加顺序 / FMA 融合的差异 → Float32 相对误差
// 在 1e-7 量级，1e-3 留了约 4 个数量级余量；同时它远小于「语义写错」会造成的偏差
// （索引差 1 像素、小数权重取错、clamp 方向错都会到 1e-2 以上），也远小于 FP16 量化误差
// （FP16 网格坐标的像素误差约 0.24 像素，见 Tools/ModelConvert/README.md）——所以这个阈值
// 既容得下浮点重排，又拦得住真错误。
import DDScannerCore
import Foundation
import Testing

@Suite("GridResample 等价性（向量化 vs 标量参考实现）")
struct GridResampleEquivalenceTests {
    /// 等价阈值；反向验证时临时改成 1e-9 → 必须红（证明本契约真的在两个实现之间比）。
    private static let tolerance: Float = 1e-3

    private static func maxAbsoluteDifference(_ lhs: FloatImage, _ rhs: FloatImage) -> Float {
        precondition(
            lhs.width == rhs.width && lhs.height == rhs.height && lhs.channels == rhs.channels,
            "两张图尺寸/通道必须一致才能比对"
        )
        var maximum: Float = 0
        for index in 0 ..< lhs.values.count {
            maximum = max(maximum, abs(lhs.values[index] - rhs.values[index]))
        }
        return maximum
    }

    @discardableResult
    private static func expectEquivalent(
        grid: NormalizedSampleGrid,
        source: FloatImage,
        targetWidth: Int,
        targetHeight: Int
    ) -> Float {
        let accelerated = GridResampler.resample(
            grid: grid, source: source, targetWidth: targetWidth, targetHeight: targetHeight
        )
        let reference = ScalarGridResamplerReference.resample(
            grid: grid, source: source, targetWidth: targetWidth, targetHeight: targetHeight
        )
        let difference = maxAbsoluteDifference(accelerated, reference)
        #expect(
            difference <= tolerance,
            "向量化实现与标量参考实现最大绝对差 \(difference) > 阈值 \(tolerance)"
        )
        return difference
    }

    // MARK: - 确定性图案（不依赖随机数种子，跑两次结果一致）

    /// 三通道图案图：R 横渐变、G 纵渐变、B 棋盘（有高频，能暴露插值/索引错误）。
    private static func patternImage(width: Int, height: Int) -> FloatImage {
        let plane = width * height
        var values = [Float](repeating: 0, count: plane * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x
                values[index] = Float(x) / Float(max(width - 1, 1))
                values[plane + index] = Float(y) / Float(max(height - 1, 1))
                values[2 * plane + index] = ((x / 2 + y / 3) % 2 == 0) ? 0.25 : 0.75
            }
        }
        return FloatImage(width: width, height: height, channels: 3, values: values)
    }

    private static func grayscale(_ rows: [[Float]]) -> FloatImage {
        FloatImage(width: rows[0].count, height: rows.count, channels: 1, values: rows.flatMap { $0 })
    }

    /// 平滑弯曲网格（31×45，量级与 UVDoc 产物一致）：坐标含正弦扰动，覆盖非整数索引路径。
    private static func warpedGrid(columns: Int = 31, rows: Int = 45) -> NormalizedSampleGrid {
        var xValues = [Float]()
        var yValues = [Float]()
        xValues.reserveCapacity(columns * rows)
        yValues.reserveCapacity(columns * rows)
        for row in 0 ..< rows {
            let v = rows > 1 ? Float(row) / Float(rows - 1) : 0
            for column in 0 ..< columns {
                let u = columns > 1 ? Float(column) / Float(columns - 1) : 0
                let x = u * 2 - 1 + 0.06 * sin(v * 3.1)
                let y = v * 2 - 1 + 0.05 * cos(u * 2.7)
                xValues.append(min(max(x, -1), 1))
                yValues.append(min(max(y, -1), 1))
            }
        }
        return NormalizedSampleGrid(columns: columns, rows: rows, xValues: xValues, yValues: yValues)
    }

    // MARK: - 契约用例

    @Test("identity 网格 + 同分辨率：两实现一致，且逐像素等于原图")
    func identityAtSameResolution() {
        let source = Self.patternImage(width: 9, height: 7)
        let output = GridResampler.resample(grid: .identity(columns: 9, rows: 7), source: source)
        Self.expectEquivalent(grid: .identity(columns: 9, rows: 7), source: source, targetWidth: 9, targetHeight: 7)
        for index in 0 ..< source.values.count {
            #expect(abs(output.values[index] - source.values[index]) < 1e-5)
        }
    }

    @Test("2×2 identity 网格插值到全分辨率：两实现一致（线性函数插值精确）")
    func identityFromCoarseGrid() {
        let source = Self.patternImage(width: 11, height: 6)
        Self.expectEquivalent(grid: .identity(columns: 2, rows: 2), source: source, targetWidth: 11, targetHeight: 6)
    }

    @Test("人工小网格 3×2 → 7×5：两实现一致")
    func artificialSmallGrid() {
        let grid = NormalizedSampleGrid(
            columns: 3,
            rows: 2,
            xValues: [-1, -0.2, 1, -0.9, 0.3, 0.8],
            yValues: [-1, -0.4, 0, 1, 0.6, 0.2]
        )
        let source = Self.patternImage(width: 8, height: 8)
        Self.expectEquivalent(grid: grid, source: source, targetWidth: 7, targetHeight: 5)
    }

    @Test("越界网格坐标 clamp 到边缘：两实现一致，且取到边缘像素值")
    func boundaryClamp() {
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [-3], yValues: [5])
        let source = Self.grayscale([[0, 1], [2, 3]])
        Self.expectEquivalent(grid: grid, source: source, targetWidth: 9, targetHeight: 7)
        let output = GridResampler.resample(grid: grid, source: source, targetWidth: 1, targetHeight: 1)
        // x → 像素 0，y → 像素 1 → 左下角值 2
        #expect(abs((output.value(x: 0, y: 0, channel: 0) ?? .nan) - 2) < 1e-6)
    }

    @Test("1×1 网格 → 4×3：两实现一致，且等于中心双线性均值")
    func singlePointGrid() {
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [0], yValues: [0])
        let source = Self.grayscale([[0, 1], [2, 3]])
        Self.expectEquivalent(grid: grid, source: source, targetWidth: 4, targetHeight: 3)
        let output = GridResampler.resample(grid: grid, source: source, targetWidth: 4, targetHeight: 3)
        for row in 0 ..< 3 {
            for column in 0 ..< 4 {
                #expect(abs((output.value(x: column, y: row, channel: 0) ?? .nan) - 1.5) < 1e-5)
            }
        }
    }

    @Test("非方形网格 5×9 → 13×11：两实现一致")
    func nonSquareGrid() {
        var xValues = [Float]()
        var yValues = [Float]()
        for row in 0 ..< 9 {
            for column in 0 ..< 5 {
                xValues.append(Float(column) / 4 * 2 - 1 + 0.1 * sin(Float(row)))
                yValues.append(Float(row) / 8 * 2 - 1 - 0.1 * cos(Float(column)))
            }
        }
        let grid = NormalizedSampleGrid(columns: 5, rows: 9, xValues: xValues, yValues: yValues)
        Self.expectEquivalent(grid: grid, source: Self.patternImage(width: 13, height: 11), targetWidth: 13, targetHeight: 11)
    }

    @Test("网格含 NaN / ±∞：两实现都回落到归一化 0，输出无 NaN")
    func nonFiniteGridFallsBack() {
        let grid = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [.nan], yValues: [.infinity])
        let source = Self.grayscale([[0, 1], [2, 3]])
        Self.expectEquivalent(grid: grid, source: source, targetWidth: 5, targetHeight: 4)
        let output = GridResampler.resample(grid: grid, source: source, targetWidth: 5, targetHeight: 4)
        let outputIsFinite = output.values.allSatisfy(\.isFinite)
        #expect(outputIsFinite)
        #expect(abs((output.value(x: 0, y: 0, channel: 0) ?? .nan) - 1.5) < 1e-5)
    }

    @Test("等价性在真实量级上仍成立：97×131 源图 + 31×45 弯曲网格（RGB）")
    func warpedGridAtRealisticScale() {
        let source = Self.patternImage(width: 97, height: 131)
        let difference = Self.expectEquivalent(
            grid: Self.warpedGrid(), source: source, targetWidth: 97, targetHeight: 131
        )
        // 反向验证依赖这一条：两实现的浮点重排必须真的带来非零差异（否则 1e-9 也过）。
        #expect(difference > 0, "两实现输出完全逐位相同，等价性契约失去意义")
    }

    @Test("灰度单通道与 RGB 三通道都走同一路径")
    func channelCountsAreHandled() {
        let grayGrid = Self.warpedGrid(columns: 7, rows: 5)
        Self.expectEquivalent(grid: grayGrid, source: Self.grayscale([[0, 1, 2, 3, 4], [5, 6, 7, 8, 9]]), targetWidth: 5, targetHeight: 2)
        Self.expectEquivalent(grid: grayGrid, source: Self.patternImage(width: 5, height: 2), targetWidth: 5, targetHeight: 2)
    }
}
