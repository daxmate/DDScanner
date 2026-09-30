// SourceCoveringGrid —— 「覆盖整幅源图」网格扩展的纯逻辑测试（本机 `swift test` 可跑，无模拟器）。
//
// 守三条语义：
//   ① 内容不丢：整体内缩的网格在修复前四边标记 = 0（反向锚，证明用例真能红），修复后四边 > 0；
//   ② 内部几何不变：外推不碰内部点（逐点残差 = 0）；归一化对内部只是一次按轴仿射；
//   ③ 安全：已覆盖网格是逐点相等的 no-op；退化 / 非有限值 / 非单调输入不崩、行为明确。
import Testing
@testable import DDScannerCore

@Suite("SourceCoveringGrid")
struct SourceCoveringGridTests {
    // MARK: - 夹具

    /// 整体内缩的 3×3 网格（坐标 ∈ [-0.6, 0.6]），代表「模型输出只覆盖源图一个子矩形」。
    private var shrunkGrid: NormalizedSampleGrid {
        NormalizedSampleGrid(
            columns: 3,
            rows: 3,
            xValues: [-0.6, 0, 0.6, -0.6, 0, 0.6, -0.6, 0, 0.6],
            yValues: [-0.6, -0.6, -0.6, 0, 0, 0, 0.6, 0.6, 0.6]
        )
    }

    /// 100×100 单通道图：最外 `band` 圈像素 = 1（四边标记），其余 = 0。
    private func markedSource(width: Int = 100, height: Int = 100, band: Int = 2) -> FloatImage {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width where y < band || y >= height - band || x < band || x >= width - band {
                values[y * width + x] = 1
            }
        }
        return FloatImage(width: width, height: height, channels: 1, values: values)
    }

    /// 统计输出四边（最外一行/列）里被标记（> 0.5）的像素数。
    private func edgeMarkers(_ image: FloatImage) -> (top: Int, bottom: Int, left: Int, right: Int) {
        var top = 0
        var bottom = 0
        var left = 0
        var right = 0
        for x in 0 ..< image.width {
            if (image.value(x: x, y: 0, channel: 0) ?? 0) > 0.5 { top += 1 }
            if (image.value(x: x, y: image.height - 1, channel: 0) ?? 0) > 0.5 { bottom += 1 }
        }
        for y in 0 ..< image.height {
            if (image.value(x: 0, y: y, channel: 0) ?? 0) > 0.5 { left += 1 }
            if (image.value(x: image.width - 1, y: y, channel: 0) ?? 0) > 0.5 { right += 1 }
        }
        return (top, bottom, left, right)
    }

    /// 在网格里精确定位一个坐标点（夹具里该坐标唯一）。
    private func locate(_ x: Float, _ y: Float, in grid: NormalizedSampleGrid) -> (column: Int, row: Int)? {
        for row in 0 ..< grid.rows {
            for column in 0 ..< grid.columns
                where grid.xValues[row * grid.columns + column] == x
                && grid.yValues[row * grid.columns + column] == y
            {
                return (column, row)
            }
        }
        return nil
    }

    // MARK: - ① 内容不丢

    @Test("内容不丢：修复前四边标记全丢（= 0），修复后四条边全部回来（> 0）")
    func coveringSourceRestoresEdges() {
        let source = markedSource()
        let before = GridResampler.resample(grid: shrunkGrid, source: source)
        let after = GridResampler.resample(grid: shrunkGrid.extendedToCoverSource(), source: source)

        // 反向锚：证明这个用例真的能红（现状把四边标记全裁掉）。
        let beforeMarkers = edgeMarkers(before)
        #expect(beforeMarkers.top == 0)
        #expect(beforeMarkers.bottom == 0)
        #expect(beforeMarkers.left == 0)
        #expect(beforeMarkers.right == 0)

        let afterMarkers = edgeMarkers(after)
        #expect(afterMarkers.top > 0)
        #expect(afterMarkers.bottom > 0)
        #expect(afterMarkers.left > 0)
        #expect(afterMarkers.right > 0)
    }

    @Test("修复后网格恰好覆盖 [-1, 1]²（四边丢失 = 0）")
    func coverageIsExact() {
        let coverage = SourceCoveringGrid.coverage(of: shrunkGrid.extendedToCoverSource())
        #expect(coverage?.xmin == -1)
        #expect(coverage?.xmax == 1)
        #expect(coverage?.ymin == -1)
        #expect(coverage?.ymax == 1)
        #expect(coverage?.coversUnitSquare == true)
    }

    // MARK: - ② 内部几何不变

    @Test("内部几何不变：外推不碰内部点（逐点相等，残差 = 0）")
    func extrapolationLeavesInteriorUnchanged() throws {
        let coverage = try #require(SourceCoveringGrid.coverage(of: shrunkGrid))
        let extended = SourceCoveringGrid.extrapolate(shrunkGrid, coverage: coverage)
        let origin = try #require(locate(-0.6, -0.6, in: extended))
        for row in 0 ..< shrunkGrid.rows {
            for column in 0 ..< shrunkGrid.columns {
                let point = extended.point(column: origin.column + column, row: origin.row + row)
                #expect(point?.x == shrunkGrid.xValues[row * shrunkGrid.columns + column])
                #expect(point?.y == shrunkGrid.yValues[row * shrunkGrid.columns + column])
            }
        }
    }

    @Test("内部几何不变：归一化对内部只是一次按轴仿射（逐点残差 = 0）")
    func normalizationIsAxisAffineOnInterior() throws {
        let coverage = try #require(SourceCoveringGrid.coverage(of: shrunkGrid))
        let extrapolated = SourceCoveringGrid.extrapolate(shrunkGrid, coverage: coverage)
        let extendedCoverage = try #require(SourceCoveringGrid.coverage(of: extrapolated))
        let normalized = SourceCoveringGrid.renormalize(extrapolated)
        let origin = try #require(locate(-0.6, -0.6, in: extrapolated))
        for row in 0 ..< shrunkGrid.rows {
            for column in 0 ..< shrunkGrid.columns {
                let point = try #require(normalized.point(column: origin.column + column, row: origin.row + row))
                let sourceX = shrunkGrid.xValues[row * shrunkGrid.columns + column]
                let sourceY = shrunkGrid.yValues[row * shrunkGrid.columns + column]
                #expect(point.x == 2 * (sourceX - extendedCoverage.xmin) / extendedCoverage.xRange - 1)
                #expect(point.y == 2 * (sourceY - extendedCoverage.ymin) / extendedCoverage.yRange - 1)
            }
        }
    }

    // MARK: - ③ 安全：no-op 与退化

    @Test("已覆盖 [-1, 1]² 的网格是 no-op（逐点相等，不重采样）")
    func alreadyCoveringIsNoOp() {
        let identity = NormalizedSampleGrid.identity(columns: 6, rows: 4)
        #expect(identity.extendedToCoverSource() == identity)

        let covering = NormalizedSampleGrid(
            columns: 3,
            rows: 3,
            xValues: [-1.3, -0.2, 1.2, -1.3, -0.2, 1.2, -1.3, -0.2, 1.2],
            yValues: [-1.1, -1.1, -1.1, 0.05, 0.05, 0.05, 1.4, 1.4, 1.4]
        )
        #expect(covering.extendedToCoverSource() == covering)
    }

    @Test("退化输入：零跨度 / 非有限值 → 原样返回，不崩")
    func degenerateInputsAreNoOps() {
        let singlePoint = NormalizedSampleGrid(columns: 1, rows: 1, xValues: [0], yValues: [0])
        #expect(singlePoint.extendedToCoverSource() == singlePoint)

        let flatRow = NormalizedSampleGrid(columns: 3, rows: 1, xValues: [-0.5, 0, 0.5], yValues: [0, 0, 0])
        #expect(flatRow.extendedToCoverSource() == flatRow)

        let nonFinite = NormalizedSampleGrid(
            columns: 2,
            rows: 2,
            xValues: [.nan, 0, -0.5, 0.5],
            yValues: [-0.5, -0.5, .infinity, 0.5]
        )
        #expect(nonFinite.extendedToCoverSource() == nonFinite)
    }

    @Test("单行 / 单列网格：不崩，结果有限且覆盖 [-1, 1]²")
    func thinGridsAreWellDefined() {
        let singleColumn = NormalizedSampleGrid(columns: 1, rows: 3, xValues: [-0.5, 0, 0.5], yValues: [-0.5, 0, 0.5])
        let singleRowWithVariedY = NormalizedSampleGrid(columns: 3, rows: 1, xValues: [-0.5, 0, 0.5], yValues: [-0.3, 0, 0.3])
        for grid in [singleColumn, singleRowWithVariedY] {
            let extended = grid.extendedToCoverSource()
            let finiteX = extended.xValues.allSatisfy(\.isFinite)
            let finiteY = extended.yValues.allSatisfy(\.isFinite)
            #expect(finiteX)
            #expect(finiteY)
            #expect(SourceCoveringGrid.coverage(of: extended)?.coversUnitSquare == true)
        }
    }

    @Test("非单调网格：不崩，结果有限且覆盖 [-1, 1]²")
    func nonMonotonicGridIsWellDefined() {
        let grid = NormalizedSampleGrid(
            columns: 3,
            rows: 3,
            xValues: [-0.5, 0.2, -0.1, -0.4, 0.1, 0.3, -0.6, 0.05, 0.4],
            yValues: [-0.5, -0.4, -0.6, 0.1, 0.0, 0.2, 0.5, 0.45, 0.55]
        )
        let extended = grid.extendedToCoverSource()
        let finiteX = extended.xValues.allSatisfy(\.isFinite)
        let finiteY = extended.yValues.allSatisfy(\.isFinite)
        #expect(finiteX)
        #expect(finiteY)
        #expect(SourceCoveringGrid.coverage(of: extended)?.coversUnitSquare == true)
    }
}
